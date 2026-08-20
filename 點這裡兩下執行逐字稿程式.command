#!/bin/bash
# ==========================================================================
#  產生逐字稿 —— 日常使用就只要這一支
#  雙擊 → 選錄音檔 → 等 → 逐字稿自動打開
# ==========================================================================
set -u

APP_DIR="$HOME/Library/Application Support/MeetingTranscribe"
VENV="$APP_DIR/venv"

# 找出程式本體的位置（可能是原始資料夾，也可能是桌面上的捷徑）
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$HERE/bin/transcribe.py" ] && [ -f "$APP_DIR/install_path.txt" ]; then
  HERE="$(cat "$APP_DIR/install_path.txt")"
fi

# 逐字稿與字幕輸出到程式本體所在的資料夾，不放桌面
OUT_DIR="$HERE/逐字稿"

alert() {  # 標題, 內容
  osascript -e "display dialog \"$2\" with title \"$1\" buttons {\"好\"} default button 1 with icon note" >/dev/null 2>&1
}

if [ ! -x "$VENV/bin/python" ] || [ ! -f "$HERE/bin/transcribe.py" ]; then
  alert "還沒安裝" "請先執行資料夾裡的「安裝.command」，完成一次性設定後再使用。"
  exit 1
fi

# --- 選檔案 ---------------------------------------------------------------
clear
echo "=========================================="
echo "  會議逐字稿"
echo "=========================================="
echo
echo "請稍等幾秒，等一下會自動跳出「選擇錄音檔」的視窗。"
echo "視窗跳出來以後，再挑要轉成逐字稿的錄音檔就可以了。"
echo
echo "（如果沒馬上看到，可能被這個視窗擋住，"
echo "  或是縮在螢幕下方的 Dock，稍等一下就會出現）"
echo

AUDIO=$(osascript <<'EOF' 2>/dev/null
set theFile to choose file with prompt "請選擇要轉成逐字稿的錄音檔" of type ¬
    {"m4a", "mp3", "wav", "aac", "mp4", "mov", "caf", "aiff", "flac", "ogg", "wma"}
POSIX path of theFile
EOF
)

if [ -z "${AUDIO:-}" ]; then
  exit 0   # 使用者按了取消
fi

mkdir -p "$OUT_DIR"
clear
echo "=========================================="
echo "  正在產生逐字稿"
echo "=========================================="
echo
echo "檔案：$(basename "$AUDIO")"
echo
echo "接下來請放著等就好，不用做任何事。"
echo
echo "．這個視窗會慢慢出現幾行進度文字，那是正常的。"
echo "．不用去拉大或縮小視窗，字不會很多，這樣看剛剛好。"
echo "．中途請不要關掉這個視窗。"
echo "．跑完會自動幫你打開逐字稿檔案。"
echo
echo "（等待時電腦可以照常做別的事，只是會比較慢）"
echo

LOG="$OUT_DIR/.最近一次執行紀錄.txt"
ERRLOG="$OUT_DIR/.最近一次錯誤訊息.txt"

# 進度走 stdout（即時顯示在畫面上），雜訊走 stderr（只寫進檔案）。
# 這樣 objc 那種嚇人的警告不會洗版，但出事時仍然查得到。
# 注意：這裡不能用 grep 過濾，grep 會把輸出攢成一大塊才吐出來，
# 畫面就會整段空白、看起來像當機。
"$VENV/bin/python" -u "$HERE/bin/transcribe.py" "$AUDIO" "$OUT_DIR" 2>"$ERRLOG" | tee "$LOG"
STATUS=${PIPESTATUS[0]}

RESULT=$(grep '^__OUTPUT__' "$LOG" | tail -1 | sed 's/^__OUTPUT__//')

echo
if [ "$STATUS" -eq 0 ] && [ -n "$RESULT" ] && [ -f "$RESULT" ]; then
  osascript -e 'display notification "逐字稿已經完成" with title "會議逐字稿"' >/dev/null 2>&1
  open "$RESULT"
  open "$OUT_DIR"
  echo "完成！結果已經打開，也存在「$OUT_DIR」資料夾裡。"
  echo "這個視窗可以關掉了。"
else
  echo "出了點問題，沒有產生逐字稿。錯誤訊息如下："
  echo "------------------------------------------"
  tail -25 "$ERRLOG" 2>/dev/null
  echo "------------------------------------------"
  echo "請把這個視窗截圖傳給幫你安裝的人看一下。"
  alert "轉錄失敗" "沒有順利產生逐字稿。請把終端機視窗截圖傳給幫你安裝的人。"
fi

echo
read -r -p "按 Enter 關閉視窗…"
