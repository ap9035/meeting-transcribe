#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
會議逐字稿產生器（帶講者標記 + 時間戳）
  Step 1  用 PyAV 解碼音檔（不需系統安裝 ffmpeg）
  Step 2  pyannote 聲紋分離，算出「誰在什麼時候說話」
  Step 3  faster-whisper 轉文字，算出「說了什麼」
  Step 4  轉成台灣繁體、對上講者、輸出逐字稿

刻意「先聲紋、再轉文字」並在中間釋放模型，讓 16GB 機器的峰值記憶體維持在 ~2GB。
"""

import gc
import os
import subprocess
import sys
import time
from pathlib import Path

APP_DIR = Path.home() / "Library" / "Application Support" / "MeetingTranscribe"
TOKEN_FILE = APP_DIR / "hf_token.txt"
NAMES_FILE = Path(__file__).resolve().parent / "人名對照表.txt"

# 轉錄模型：turbo 在中文品質接近 large-v3，但快 5~8 倍，是筆電上的最佳平衡點
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "large-v3-turbo")
DIARIZATION_MODEL = "pyannote/speaker-diarization-community-1"


def log(msg):
    print(msg, flush=True)


def step(n, total, msg):
    log(f"\n[{n}/{total}] {msg}")


# --------------------------------------------------------------------------
# 人名校正：Whisper 常把人名辨識成同音錯字
# --------------------------------------------------------------------------
def load_name_map():
    """讀取人名對照表。格式：正確人名 = 誤辨1, 誤辨2, 誤辨3"""
    mapping = {}
    if not NAMES_FILE.exists():
        return mapping
    for line in NAMES_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        correct, wrongs = line.split("=", 1)
        correct = correct.strip()
        for w in wrongs.split(","):
            w = w.strip()
            if w and w != correct:
                mapping[w] = correct
    return mapping


def fix_names(text, mapping):
    # 長的先換，避免短字串先吃掉長字串的一部分
    for wrong in sorted(mapping, key=len, reverse=True):
        text = text.replace(wrong, mapping[wrong])
    return text


# --------------------------------------------------------------------------
# 繁體轉換：Whisper 的 zh 幾乎一定吐簡體，這份工具是給台灣使用者看的
# --------------------------------------------------------------------------
def _install_opencc():
    """這個環境是 uv 建的，通常沒有 pip，所以優先用 uv 補裝。"""
    uv = Path.home() / ".local" / "bin" / "uv"
    uv_bin = str(uv) if uv.is_file() else None
    if uv_bin is None:
        import shutil
        uv_bin = shutil.which("uv")
    if uv_bin:
        subprocess.check_call(
            [uv_bin, "pip", "install", "--python", sys.executable, "opencc-python-reimplemented"]
        )
        return
    subprocess.check_call(
        [sys.executable, "-m", "pip", "install", "--quiet", "opencc-python-reimplemented"]
    )


def load_traditional_converter():
    """簡體 → 台灣繁體（s2twp：軟件→軟體、信息→資訊、視頻→影片）。"""
    try:
        from opencc import OpenCC
        return OpenCC("s2twp")
    except ImportError:
        log("    缺少繁簡轉換套件，正在補裝…")
        try:
            _install_opencc()
            from opencc import OpenCC
            return OpenCC("s2twp")
        except Exception as e:
            raise RuntimeError(
                "無法安裝繁簡轉換套件。請再跑一次「安裝.command」。"
            ) from e


def to_traditional(text, converter):
    if not text:
        return text
    return converter.convert(text)


# --------------------------------------------------------------------------
# 把 whisper 的句子和 pyannote 的講者區間對起來
# --------------------------------------------------------------------------
def assign_speakers(segments, turns):
    """
    segments : [(start, end, text), ...]   whisper 的句子
    turns    : [(start, end, speaker), ...] pyannote 的講者區間（不重疊）
    回傳     : [(start, end, text, speaker), ...]

    作法：每個句子跟所有講者區間算時間重疊，取重疊最久的那位。
    完全沒有重疊時（例如講者模型漏抓），退回「時間軸上最接近的講者」，
    再不行才沿用上一句的講者，確保每句都有標記。
    """
    out = []
    last_speaker = None
    for s_start, s_end, text in segments:
        best_speaker, best_overlap = None, 0.0
        for t_start, t_end, speaker in turns:
            overlap = min(s_end, t_end) - max(s_start, t_start)
            if overlap > best_overlap:
                best_overlap, best_speaker = overlap, speaker

        if best_speaker is None and turns:
            # 沒重疊 → 找距離最近的區間
            mid = (s_start + s_end) / 2
            best_speaker = min(
                turns,
                key=lambda t: 0 if t[0] <= mid <= t[1] else min(abs(mid - t[0]), abs(mid - t[1])),
            )[2]

        if best_speaker is None:
            best_speaker = last_speaker or "SPEAKER_00"

        last_speaker = best_speaker
        out.append((s_start, s_end, text, best_speaker))
    return out


def label_speakers(rows):
    """把 SPEAKER_00 / SPEAKER_01 依「第一次發言的先後」重新命名成 講者1 / 講者2"""
    order, mapping = [], {}
    for _, _, _, sp in rows:
        if sp not in mapping:
            mapping[sp] = f"講者{len(order) + 1}"
            order.append(sp)
    return [(a, b, c, mapping[sp]) for a, b, c, sp in rows], mapping


def merge_same_speaker(rows, max_gap=2.0):
    """同一位講者連續的短句合併成一段，讀起來才不會一行一句很破碎"""
    merged = []
    for start, end, text, sp in rows:
        if merged and merged[-1][3] == sp and start - merged[-1][1] <= max_gap:
            p_start, _, p_text, p_sp = merged[-1]
            merged[-1] = (p_start, end, (p_text + " " + text).strip(), p_sp)
        else:
            merged.append((start, end, text, sp))
    return merged


def hhmmss(sec):
    sec = int(sec)
    return f"{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


# --------------------------------------------------------------------------
# 幻覺（hallucination）防護：Whisper 偶爾會在靜音／訊噪比低的片段裡
# 卡進複讀迴圈，連續吐出同一句話（常見於 large-v3 系列，跟訓練資料裡
# 混入大量 YouTube 影片的罐頭口播、字幕組宣傳有關）
# --------------------------------------------------------------------------
DEDUPE_MIN_LEN = 6  # 正規化後未達此字數不處理，避免誤殺「對，對」「嗯嗯」這類正常口語


def _normalize_for_dedupe(text):
    return text.strip().strip("。！？，、,.!?～~ \u3000")


def dedupe_repeated_segments(segments, min_len=DEDUPE_MIN_LEN):
    """合併連續且完全相同的句子。

    只處理正規化後長度達到 min_len 的句子：太短的重複（確認語、口頭禪）
    是正常口語，保留原樣；達到門檻的完整句子連續重複兩次以上，
    在會議逐字稿情境下幾乎都是模型卡住複讀，直接合併成一句，
    並把結束時間延伸蓋住被丟掉的重複範圍，維持時間軸連續。
    """
    if not segments:
        return segments
    deduped = []  # 每個元素: [start, end, text, normalized]
    dropped = 0
    for start, end, text in segments:
        norm = _normalize_for_dedupe(text)
        if deduped and len(norm) >= min_len and norm == deduped[-1][3]:
            deduped[-1][1] = end
            dropped += 1
            continue
        deduped.append([start, end, text, norm])
    if dropped:
        log(f"    偵測到 {dropped} 句疑似複讀幻覺，已自動合併")
    return [(s, e, t) for s, e, t, _ in deduped]


# --------------------------------------------------------------------------
def main():
    if len(sys.argv) < 2:
        log("用法：transcribe.py <音檔路徑> [輸出資料夾]")
        return 2

    audio_path = Path(sys.argv[1]).expanduser()
    out_dir = (
        Path(sys.argv[2]).expanduser()
        if len(sys.argv) > 2
        else Path(__file__).resolve().parent.parent / "逐字稿"
    )
    if not audio_path.exists():
        log(f"找不到檔案：{audio_path}")
        return 2
    out_dir.mkdir(parents=True, exist_ok=True)

    t0 = time.time()
    TOTAL = 4

    # ---- Step 1 解碼 ----------------------------------------------------
    step(1, TOTAL, f"讀取音檔：{audio_path.name}")
    from faster_whisper.audio import decode_audio  # PyAV，內建 ffmpeg，免另外安裝

    audio = decode_audio(str(audio_path), sampling_rate=16000)
    duration = len(audio) / 16000
    log(f"    長度 {hhmmss(duration)}（{duration:.0f} 秒）")
    log(f"    預估耗時：約 {hhmmss(duration * 0.75)} ~ {hhmmss(duration * 1.5)}，請耐心等候")

    # ---- Step 2 聲紋分離 ------------------------------------------------
    step(2, TOTAL, "分辨有幾個人在說話（聲紋比對）…")
    turns = []
    token = TOKEN_FILE.read_text(encoding="utf-8").strip() if TOKEN_FILE.exists() else None
    if not token:
        log("    ⚠️  找不到 Hugging Face 授權碼，這次跳過講者辨識，只產生純逐字稿。")
        log(f"    （請重新執行「安裝.command」設定，或手動放進 {TOKEN_FILE}）")
    else:
        try:
            import torch
            from pyannote.audio import Pipeline

            pipeline = Pipeline.from_pretrained(DIARIZATION_MODEL, token=token)
            # 傳入已解碼的波形，pyannote 就不會去呼叫 torchcodec，
            # 也就不需要在系統上另外安裝 ffmpeg
            waveform = torch.from_numpy(audio).unsqueeze(0)  # (channel=1, time)

            # 這一步沒有內建進度回報，長音檔會安靜好幾分鐘看起來像當機，
            # 所以掛一個 hook 把每個子步驟的百分比印出來
            _stage = {"name": None}
            _labels = {
                "segmentation": "找出說話片段",
                "embeddings": "擷取聲紋特徵",
                "speaker_counting": "統計講者人數",
                "discrete_diarization": "整理發言區間",
            }

            def progress_hook(step_name, step_artifact, file=None, total=None, completed=None):
                label = _labels.get(step_name, step_name)
                if completed is None or total in (None, 0):
                    if _stage["name"] != step_name:
                        _stage["name"] = step_name
                        print(f"\n    · {label}…", end="", flush=True)
                    return
                if _stage["name"] != step_name:
                    _stage["name"] = step_name
                    print(f"\n    · {label}", end="", flush=True)
                print(f"\r    · {label} {int(completed / total * 100):3d}%   ", end="", flush=True)

            output = pipeline({"waveform": waveform, "sample_rate": 16000}, hook=progress_hook)
            print(flush=True)

            # exclusive_speaker_diarization：官方為了跟轉錄時間戳對齊而提供的不重疊版本
            diar = getattr(output, "exclusive_speaker_diarization", None)
            if diar is None:
                diar = output.speaker_diarization
            for turn, speaker in diar:
                turns.append((turn.start, turn.end, speaker))

            n_speakers = len({s for _, _, s in turns})
            log(f"    偵測到 {n_speakers} 位講者，共 {len(turns)} 個發言區間")

            del pipeline, output, waveform
            gc.collect()
        except Exception as e:
            log(f"    ⚠️  講者辨識失敗（{type(e).__name__}: {e}）")
            log("    改為只產生純逐字稿，轉文字不受影響。")
            turns = []

    # ---- Step 3 轉文字 --------------------------------------------------
    step(3, TOTAL, f"轉成文字（模型 {WHISPER_MODEL}）…")
    from faster_whisper import WhisperModel

    cpu_threads = max(4, (os.cpu_count() or 8) - 2)
    model = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8", cpu_threads=cpu_threads)
    seg_iter, info = model.transcribe(
        audio,
        language="zh",
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 500},
        condition_on_previous_text=False,  # 避免長會議把前面的錯誤一路複製下去
        beam_size=5,
        word_timestamps=True,  # hallucination_silence_threshold 需要逐字時間戳才能運作
        hallucination_silence_threshold=2.0,  # 靜音中疑似幻覺（複讀/罐頭句）時直接跳過該段
    )

    segments = []
    for seg in seg_iter:
        text = seg.text.strip()
        if not text:
            continue
        segments.append((seg.start, seg.end, text))
        pct = min(99, int(seg.end / duration * 100))
        print(f"\r    進度 {pct:3d}%  已完成 {hhmmss(seg.end)} / {hhmmss(duration)}", end="", flush=True)
    print(f"\r    進度 100%  共 {len(segments)} 句{' ' * 20}", flush=True)

    segments = dedupe_repeated_segments(segments)

    del model
    gc.collect()

    # ---- Step 4 合併輸出 ------------------------------------------------
    step(4, TOTAL, "整理逐字稿…")
    try:
        converter = load_traditional_converter()
    except Exception as e:
        log("    ✗ 無法啟用繁體轉換，已中止，避免輸出簡體中文。")
        log(f"    （{type(e).__name__}: {e}）")
        log("    請再跑一次「安裝.command」後重試。")
        return 2

    name_map = load_name_map()
    # 先轉台灣繁體，再套人名對照，簡體同音字才對得上對照表裡的繁體寫法
    segments = [
        (s, e, fix_names(to_traditional(t, converter), name_map))
        for s, e, t in segments
    ]
    log("    已轉成台灣繁體")

    raw_rows = assign_speakers(segments, turns) if turns else [(s, e, t, "SPEAKER_00") for s, e, t in segments]
    raw_rows, _ = label_speakers(raw_rows)
    rows = merge_same_speaker(raw_rows)

    stem = audio_path.stem
    txt_path = out_dir / f"{stem}_逐字稿.txt"
    with txt_path.open("w", encoding="utf-8") as f:
        f.write(f"檔案：{audio_path.name}\n")
        f.write(f"長度：{hhmmss(duration)}\n")
        if turns:
            f.write(f"講者人數：{len({sp for *_, sp in rows})}\n")
        else:
            f.write("講者人數：未辨識（本次未啟用聲紋分離）\n")
        f.write("=" * 50 + "\n\n")
        for start, _end, text, sp in rows:
            if turns:
                f.write(f"[{hhmmss(start)}] {sp}：{text}\n\n")
            else:
                f.write(f"[{hhmmss(start)}] {text}\n\n")

    def srt_ts(x):
        ms = int(round(x * 1000))
        return f"{ms // 3600000:02d}:{ms % 3600000 // 60000:02d}:{ms % 60000 // 1000:02d},{ms % 1000:03d}"

    # 字幕用未合併的原始句子，時間軸才會準
    srt_path = out_dir / f"{stem}_字幕.srt"
    with srt_path.open("w", encoding="utf-8") as f:
        for i, (start, end, text, sp) in enumerate(raw_rows, 1):
            body = f"{sp}：{text}" if turns else text
            f.write(f"{i}\n{srt_ts(start)} --> {srt_ts(end)}\n{body}\n\n")

    elapsed = time.time() - t0
    log(f"\n完成！耗時 {hhmmss(elapsed)}（音檔 {hhmmss(duration)}，速度 {duration / max(elapsed, 1):.1f}x 實時）")
    log(f"逐字稿：{txt_path}")
    print(f"__OUTPUT__{txt_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
