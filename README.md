# 會議逐字稿工具

把錄音檔轉成**帶講者標記、時間戳、台灣繁體**的逐字稿。全部在自己的 Mac 上跑，錄音不會上傳到任何地方。

```
[00:00:00] 講者1：各位早安，今天我們要討論第三季的預算分配。

[00:00:06] 講者2：好的，我這邊先報告目前的執行狀況。
```

適合不想把會議錄音丟上雲端的場合。目標機器是 Apple Silicon、16GB 記憶體的筆電。

## 功能

- 本機離線轉錄，音檔不離開這台電腦
- 自動標示講者（講者1、講者2…）與時間戳
- 輸出台灣繁體（軟件→軟體、信息→資訊、視頻→影片）
- 人名對照表：把 Whisper 聽錯的同音字一次改對
- 同時產出 `.txt`（給人看）和 `.srt`（字幕）
- 不需要 Homebrew，也不需要另外安裝 ffmpeg

把資料夾拷到另一台 Mac 時，也可直接看 [使用說明.md](使用說明.md)。

## 環境需求

- macOS（以 M1 / 16GB 驗證）
- git（macOS 沒內建，見下方步驟 0；不需要 Homebrew）
- 網路：僅安裝當下需要，用來下載 Python 套件、語音模型，以及 Hugging Face 授權碼
- 約 1.5GB 磁碟空間給模型

> 完全沒有終端機經驗的人，請改看 [使用說明.md](使用說明.md)，那份從「怎麼打開終端機」開始一步步寫。

## 安裝（只做一次）

### 步驟 0：確認有 git

macOS 預設沒有裝 git。打開「終端機」（⌘+空白鍵 → 輸入「終端機」→ Enter），執行：

```bash
git --version
```

- 印出 `git version …` → 已經有了，跳到步驟 1。
- 跳出「要安裝命令列開發者工具嗎？」的視窗 → 按「安裝」→「同意」，等它裝完（5～20 分鐘），
  再執行一次 `git --version` 確認。視窗被關掉的話，用 `xcode-select --install` 叫回來。
- 印出 `command not found: git` → 同樣執行 `xcode-select --install`。

這是 Apple 官方的 Xcode Command Line Tools，不需要 Homebrew，也不會動到系統其他東西。

### 步驟 1：下載並安裝

**請用 `git clone` 下載，不要從 GitHub 網頁按「Download ZIP」。**
瀏覽器下載、AirDrop、訊息傳過來的檔案會被 macOS 貼上「隔離（quarantine）」標記，雙擊時會被 Gatekeeper 擋下來；`git clone` 抓下來的檔案沒有這個標記，可以直接執行。（`更新.command` 本來也需要資料夾是 `git clone` 來的才能運作。）

一行搞定下載 + 安裝：

```bash
cd ~/Documents && git clone https://github.com/ap9035/meeting-transcribe.git && bash meeting-transcribe/安裝.command
```

或者分開做：

1. `git clone https://github.com/ap9035/meeting-transcribe.git`，把資料夾放到固定位置，之後不要再搬（例如「文件」）。
2. 雙擊 `安裝.command`。
   萬一被擋（畫面說「無法打開，因為來自未識別的開發者」），表示這包是用下載或 AirDrop 傳來的。**打開「終端機」→ 輸入 `bash` 和一個空格 → 把 `安裝.command` 從 Finder 直接拖進終端機視窗 → 按 Enter。**
   從終端機執行不經過 Gatekeeper，一定跑得起來，也不用自己打路徑。
   （`安裝.command` 跑完會自動解除整包的隔離標記，之後日常使用都不會再遇到這個問題。）
3. 照畫面走完。中間會請你貼一組 Hugging Face **Read** token，用來下載講者辨識模型：
   - 註冊：<https://huggingface.co/join>
   - 同意條款：<https://huggingface.co/pyannote/speaker-diarization-community-1>
   - 建立 token：<https://huggingface.co/settings/tokens>（複製 `hf_` 開頭那串）
4. 裝完桌面會出現「📝 產生逐字稿」和「🔄 更新工具」。建議先拿 5 分鐘的錄音測一次。
5. 打開 `bin/人名對照表.txt`，把常出現的同事、客戶、專有名詞加進去。

安裝約 10–20 分鐘。之後完全離線。

若跳過授權碼，仍然可以轉逐字稿，只是不會標講者。

## 日常使用

1. 雙擊桌面的「📝 產生逐字稿」
2. 選錄音檔（m4a / mp3 / wav / aac / mp4 / mov…）
3. 等它跑完，逐字稿會自動打開

成品在這個專案資料夾底下的「逐字稿」資料夾。

## 大概要等多久

在 M1 / 16GB 上，**1 小時會議大約 45–75 分鐘**。期間電腦可以照常用，只是會比較燙、比較慢。建議開完會就按下去，去做別的事。

想換速度／準確度，可改 `bin/transcribe.py` 裡的 `WHISPER_MODEL`（預設 `large-v3-turbo`），或設環境變數：

```bash
WHISPER_MODEL=medium ./逐字稿.command
```

`medium` / `small` 比較快，中文人名和專有名詞會比較容易錯。

## 人名對照

Whisper 很常把中文人名聽成同音錯字。編輯 `bin/人名對照表.txt`：

```
正確人名 = 錯誤寫法1, 錯誤寫法2, 錯誤寫法3
```

井字號開頭是註解。改完存檔即可，不用重裝。

## 更新

有新版本時，雙擊桌面的「🔄 更新工具」（或專案資料夾裡的 `更新.command`）即可：

1. 自動暫存本機修改（例如你編輯過的 `bin/人名對照表.txt`）
2. 下載並套用最新版本
3. 還原剛剛暫存的修改
4. 如果套件版本有更新，一併重新安裝

全程不需要重跑 `安裝.command`，也不會遺失你的人名對照設定。

> 第一次要用「🔄 更新工具」之前，這個資料夾要先是用 `git clone` 下載的（照上面「安裝」步驟做就符合）。如果是舊版、資料夾裡還沒有 `更新.command`，先手動執行一次 `git pull`，或重新 `git clone` 一份，之後就都能用「🔄 更新工具」了。

## 檔案位置

| 東西 | 位置 |
|---|---|
| 逐字稿成品 | 專案資料夾 →「逐字稿」 |
| 人名對照表 | `bin/人名對照表.txt` |
| Python 環境與模型 | `~/Library/Application Support/MeetingTranscribe/` |
| Hugging Face 授權碼 | `~/Library/Application Support/MeetingTranscribe/hf_token.txt` |

授權碼只存在本機，不會進 Git。

## 出問題時

| 狀況 | 處理 |
|---|---|
| `command not found: git` | 執行 `xcode-select --install`，按「安裝」，裝完再試 |
| clone 時說 `already exists and is not an empty directory` | 已經下載過了，直接跑 `bash ~/Documents/meeting-transcribe/安裝.command` |
| 雙擊沒反應／「無法打開，來自未識別的開發者」 | 開「終端機」，輸入 `bash` 加空格，把該檔案從 Finder 拖進去按 Enter |
| 說「還沒安裝」 | 重跑一次 `安裝.command` |
| 沒有講者標記 | 授權碼沒設好，或還沒在模型頁按同意。重跑安裝 |
| 卡住超過 10 分鐘 | 多半是長靜音。把前後靜音剪掉再試 |
| 人名一直錯 | 加到 `bin/人名對照表.txt` |
| 出現簡體中文 | 重跑一次 `安裝.command`，讓繁簡轉換套件裝進去 |
| 更新失敗（網路問題） | 檢查網路連線後，再點一次「🔄 更新工具」 |
| 更新後本機修改跟新版本衝突 | 修改還安全留在 `git stash` 裡，找當初幫你安裝的人協助處理 |

## 技術說明

流程刻意「先聲紋、再轉文字」，中間釋放模型，讓 16GB 機器峰值記憶體維持在約 2GB。

1. **PyAV** 解碼音檔（wheel 自帶 ffmpeg）
2. **pyannote** `speaker-diarization-community-1` 分離講者
3. **faster-whisper** `large-v3-turbo`（CPU、int8、`language=zh`）轉文字
4. **OpenCC** `s2twp` 轉成台灣繁體，再套人名對照、對齊時間戳後輸出

Python 環境由 `uv` 建在獨立目錄，不會動到系統 Python。

## 移除

刪掉以下即可：

- `~/Library/Application Support/MeetingTranscribe/`
- `~/.cache/huggingface/`
- 桌面上的「📝 產生逐字稿」與「🔄 更新工具」捷徑
- 這個專案資料夾（含裡面的「逐字稿」輸出資料夾）
