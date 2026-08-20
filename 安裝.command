#!/bin/bash
# ==========================================================================
#  會議逐字稿工具 —— 一次性安裝
#  這支只需要跑一次。跑完之後，日常使用只要雙擊「點這裡兩下執行逐字稿程式.command」。
# ==========================================================================
set -u

# --------------------------------------------------------------------------
# 下面整支包在一對大括號裡，看起來多餘，其實是必要的保險：
# bash 是「執行到哪、才從檔案讀到哪」，所以程式跑到一半時檔案若被改掉
# （更新工具 git pull 換掉自己、或有人在旁邊編輯），bash 會接著讀到錯位的
# 內容而爆出莫名的語法錯誤。包成一個複合指令，bash 會先把整段讀進記憶體，
# 開跑之後就不再回頭讀檔，跑到一半被換掉也不受影響。
# --------------------------------------------------------------------------
{

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/Library/Application Support/MeetingTranscribe"
VENV="$APP_DIR/venv"
TOKEN_FILE="$APP_DIR/hf_token.txt"

cd "$HERE"
clear
echo "=========================================="
echo "  會議逐字稿工具 · 安裝程式"
echo "=========================================="
echo
echo "這會在你的電腦上建立一套完全離線的語音轉文字環境。"
echo "全程約需 10～20 分鐘（大部分時間在下載模型），需要保持連網。"
echo "安裝後所有錄音都在本機處理，不會上傳到任何地方。"
echo
read -r -p "按 Enter 開始，或按 Ctrl+C 取消…"

mkdir -p "$APP_DIR"

# --- 1. 安裝 uv（自帶 Python，不需要 Homebrew，也不會動到系統 Python）------
echo
echo "[1/5] 準備 Python 環境…"
UV="$HOME/.local/bin/uv"
if [ ! -x "$UV" ]; then
  if command -v uv >/dev/null 2>&1; then
    UV="$(command -v uv)"
  else
    echo "      下載 uv…"
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
    UV="$HOME/.local/bin/uv"
  fi
fi
if [ ! -x "$UV" ]; then
  echo "      ✗ uv 安裝失敗，請確認網路連線後重試。"
  read -r -p "按 Enter 關閉…"; exit 1
fi
echo "      ✓ uv 就緒"

# --- 2. 建立獨立虛擬環境 --------------------------------------------------
echo
echo "[2/5] 建立獨立環境（不會影響你電腦上其他程式）…"
"$UV" venv --python 3.12 "$VENV" >/dev/null 2>&1 || {
  echo "      ✗ 建立環境失敗"; read -r -p "按 Enter 關閉…"; exit 1; }
echo "      ✓ 完成"

# --- 3. 安裝套件 ----------------------------------------------------------
echo
echo "[3/5] 安裝語音辨識套件（這一步最久，約 5～10 分鐘）…"
export VIRTUAL_ENV="$VENV"
"$UV" pip install --python "$VENV/bin/python" \
    "faster-whisper>=1.2" "pyannote.audio>=4.0" "opencc-python-reimplemented" 2>&1 | grep -Ei "error|Installed|Prepared" | tail -5
if ! "$VENV/bin/python" -c "import faster_whisper, pyannote.audio, opencc; from opencc import OpenCC; assert OpenCC('s2twp').convert('\u8f6f\u4ef6') == '\u8edf\u9ad4'" 2>/dev/null; then
  echo "      ✗ 套件安裝失敗，請截圖這個畫面回報。"
  read -r -p "按 Enter 關閉…"; exit 1
fi
echo "      ✓ 完成"

# --- 4. Hugging Face 授權碼 ----------------------------------------------
echo
echo "[4/5] 設定講者辨識授權碼"
echo
if [ -s "$TOKEN_FILE" ]; then
  echo "      已經設定過了，跳過。"
  echo "      （要換一組的話，先刪掉 $TOKEN_FILE 再重跑）"
else
  cat <<'EOF'
      辨識「誰在說話」的模型需要一組免費授權碼，只要設定一次。
      取得方式（約 3 分鐘）：

        1. 到 https://huggingface.co/join 註冊免費帳號
        2. 到 https://huggingface.co/pyannote/speaker-diarization-community-1
           把頁面上的使用條款按「Agree / Accept」同意
        3. 到 https://huggingface.co/settings/tokens
           按 New token，Type 選「Read」，建立後複製那串 hf_ 開頭的字

      把那串字貼在下面（貼上後按 Enter）。
      直接按 Enter 跳過的話，仍然可以轉逐字稿，只是不會標示講者。

EOF
  read -r -p "      授權碼：" HF_TOKEN
  if [ -n "${HF_TOKEN:-}" ]; then
    printf '%s' "$HF_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "      ✓ 已儲存"
  else
    echo "      （已跳過，之後重跑這支程式就能補設定）"
  fi
fi

# --- 5. 預先下載模型，讓第一次使用不用等 ----------------------------------
echo
echo "[5/5] 預先下載模型（約 1.5GB，之後就完全離線）…"
"$VENV/bin/python" - <<'PY'
import os, sys, pathlib
try:
    from faster_whisper import WhisperModel
    print("      下載轉錄模型 large-v3-turbo…", flush=True)
    WhisperModel("large-v3-turbo", device="cpu", compute_type="int8")
    print("      ✓ 轉錄模型完成", flush=True)
except Exception as e:
    print(f"      ⚠️ 轉錄模型下載失敗：{e}", flush=True)

tok = pathlib.Path.home()/"Library/Application Support/MeetingTranscribe/hf_token.txt"
if tok.exists() and tok.read_text().strip():
    try:
        from pyannote.audio import Pipeline
        print("      下載講者辨識模型…", flush=True)
        p = Pipeline.from_pretrained("pyannote/speaker-diarization-community-1",
                                     token=tok.read_text().strip())
        if p is None:
            raise RuntimeError("授權碼無效，或尚未在網頁上同意使用條款")
        print("      ✓ 講者辨識模型完成", flush=True)
    except Exception as e:
        print(f"      ⚠️ 講者辨識模型下載失敗：{e}", flush=True)
        print("         多半是還沒到模型頁面按同意，或授權碼打錯。", flush=True)
        print("         重跑一次本安裝程式即可修正。", flush=True)
PY

# --- 收尾：把日常入口放到桌面，並解除下載隔離 ------------------------------
# 解除「從網路下載」的隔離標記，不然 macOS 會擋著不給雙擊。
# 注意：有些 macOS 版本的 xattr 不支援 -r，所以用 find 一個一個處理才保險。
unquarantine() {
  [ -e "$1" ] || return 0
  find "$1" -exec xattr -d com.apple.quarantine {} \; 2>/dev/null
  return 0
}

unquarantine "$HERE"
chmod +x "$HERE/點這裡兩下執行逐字稿程式.command" "$HERE/更新.command" 2>/dev/null
mkdir -p "$HERE/逐字稿"

DESKTOP_LINK="$HOME/Desktop/📝 點這裡兩下執行逐字稿程式.command"
# 舊版本的桌面捷徑名稱，換名字後把它清掉，免得桌面上留兩個
rm -f "$HOME/Desktop/📝 產生逐字稿.command" 2>/dev/null
cp "$HERE/點這裡兩下執行逐字稿程式.command" "$DESKTOP_LINK" 2>/dev/null
# 讓桌面捷徑知道程式本體在哪
printf '%s\n' "$HERE" > "$APP_DIR/install_path.txt"
chmod +x "$DESKTOP_LINK" 2>/dev/null
unquarantine "$DESKTOP_LINK"

UPDATE_LINK="$HOME/Desktop/🔄 更新工具.command"
if [ -f "$HERE/更新.command" ]; then
  cp "$HERE/更新.command" "$UPDATE_LINK" 2>/dev/null
  chmod +x "$UPDATE_LINK" 2>/dev/null
  unquarantine "$UPDATE_LINK"
fi

echo
echo "=========================================="
echo "  安裝完成 🎉"
echo "=========================================="
echo
echo "桌面上已經放好「📝 點這裡兩下執行逐字稿程式」和「🔄 更新工具」。"
echo "以後要轉錄，雙擊「📝 點這裡兩下執行逐字稿程式」、選音檔就好，不用再開這個視窗。"
echo "結果會存到這個資料夾底下的「逐字稿」資料夾（$HERE/逐字稿）。"
echo
echo "以後有新版本時，雙擊「🔄 更新工具」就能更新，不用重跑這支安裝程式。"
echo
read -r -p "按 Enter 關閉…"

# 明確在這裡結束，bash 就不會再回頭去讀檔案剩下的部分
exit 0

}   # ←（對應開頭那個「先整段讀完再執行」的大括號）
