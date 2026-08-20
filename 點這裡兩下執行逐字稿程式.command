#!/bin/bash
# ==========================================================================
#  產生逐字稿 —— 日常使用就只要這一支
#  雙擊 → 等視窗跳出 → 選錄音檔 → 等 → 逐字稿自動打開
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

APP_DIR="$HOME/Library/Application Support/MeetingTranscribe"
VENV="$APP_DIR/venv"
LOG_DIR="$APP_DIR/logs"
LOCK_DIR="$APP_DIR/正在執行.lock"

# 找出程式本體的位置（可能是原始資料夾，也可能是桌面上的捷徑）
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
find_program() {
  # 1) 自己就放在程式資料夾裡
  [ -f "$HERE/bin/transcribe.py" ] && return 0
  # 2) 安裝時記下來的位置（桌面捷徑走這條）
  if [ -f "$APP_DIR/install_path.txt" ]; then
    local saved
    saved="$(cat "$APP_DIR/install_path.txt" 2>/dev/null)"
    if [ -n "$saved" ] && [ -f "$saved/bin/transcribe.py" ]; then
      HERE="$saved"
      return 0
    fi
  fi
  # 3) 資料夾被搬走或改名了 → 在常見位置找一下，找到就順手把記錄修好，
  #    使用者才不會因為整理桌面就整組壞掉。
  local found
  found="$(find "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" \
             -maxdepth 3 -path '*/bin/transcribe.py' -print -quit 2>/dev/null)"
  if [ -n "$found" ]; then
    HERE="$(cd "$(dirname "$found")/.." && pwd)"
    printf '%s\n' "$HERE" > "$APP_DIR/install_path.txt" 2>/dev/null
    return 0
  fi
  return 1
}
FOUND_PROGRAM=0
find_program && FOUND_PROGRAM=1

# 逐字稿與字幕輸出到程式本體所在的資料夾，不放桌面
OUT_DIR="$HERE/逐字稿"

# --- 畫面樣式 -------------------------------------------------------------
# 只有真的輸出到終端機時才上色，避免存成檔案時混進一堆亂碼
if [ -t 1 ]; then
  # 選中間調的顏色：終端機不管是白底還是黑底都看得清楚
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[38;5;160m'; GREEN=$'\033[38;5;35m'; YEL=$'\033[38;5;166m'
  CYAN=$'\033[38;5;33m'; PINK=$'\033[38;5;168m'; GREY=$'\033[38;5;244m'
else
  B=""; D=""; R=""; RED=""; GREEN=""; YEL=""; CYAN=""; PINK=""; GREY=""
fi
LINE="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

banner() {  # 標題文字, 顏色
  local color="${2:-$CYAN}"
  printf '\n%s%s%s\n' "$color" "$LINE" "$R"
  printf '%s%s   %s%s\n' "$B" "$color" "$1" "$R"
  printf '%s%s%s\n\n' "$color" "$LINE" "$R"
}

say()  { printf '%s   %s%s\n' "$B" "$1" "$R"; }            # 一般說明
item() { printf '%s   ●%s %s\n' "$CYAN" "$R" "$1"; }       # 條列
note() { printf '%s   %s%s\n' "$D$GREY" "$1" "$R"; }       # 補充小字
warn() { printf '%s   %s%s\n' "$YEL" "$1" "$R"; }          # 要注意的
blank(){ printf '\n'; }

title_bar() { printf '\033]0;%s\007' "$1"; }               # 設定視窗標題

alert() {  # 標題, 內容
  osascript -e "display dialog \"$2\" with title \"$1\" buttons {\"好\"} default button 1 with icon note" >/dev/null 2>&1
}

pause_close() {
  blank
  printf '%s   按一下 Enter 就可以關掉這個視窗…%s ' "$D$GREY" "$R"
  read -r
}

title_bar "會議逐字稿"

if [ "$FOUND_PROGRAM" -ne 1 ]; then
  clear
  banner "找不到程式資料夾" "$RED"
  say "原本放程式的資料夾好像被搬走、改名或刪掉了。"
  blank
  item "請找到「meeting-transcribe」那個資料夾。"
  item "打開它，雙擊裡面的「安裝.command」跑一次就會修好。"
  alert "找不到程式資料夾" "放程式的資料夾被搬走或改名了。請找到該資料夾，雙擊裡面的「安裝.command」跑一次。"
  pause_close
  exit 1
fi

if [ ! -x "$VENV/bin/python" ]; then
  clear
  banner "還沒完成安裝" "$RED"
  say "第一次使用要先做一次性設定。"
  blank
  item "請打開程式資料夾，雙擊「安裝.command」。"
  item "跑完之後再回來雙擊這個檔案就可以了。"
  alert "還沒安裝" "請先執行資料夾裡的「安裝.command」，完成一次性設定後再使用。"
  pause_close
  exit 1
fi

# --- 同時只准跑一份 -------------------------------------------------------
# mkdir 是原子操作，兩個視窗同時搶只會有一個成功。
# 若上一次是被強制關掉留下的殘骸（PID 已不存在），就自動清掉再繼續。
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  OLD_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
  OLD_START="$(cat "$LOCK_DIR/start" 2>/dev/null || echo "")"
  # 光看 PID 還不夠：PID 會被系統回收給別的程式用。連「行程啟動時間」一起比對，
  # 兩個都一樣才算是真的還在跑，這樣判斷跟檔名叫什麼無關。
  NOW_START="$(ps -p "${OLD_PID:-0}" -o lstart= 2>/dev/null || echo "")"
  if [ -n "$OLD_PID" ] && [ -n "$OLD_START" ] && [ "$NOW_START" = "$OLD_START" ]; then
    clear
    banner "已經有一份正在轉錄中" "$YEL"
    say "電腦目前正在處理另一個錄音檔。"
    blank
    item "請切換到另一個黑色視窗，等它跑完。"
    item "跑完之後再回來雙擊一次就可以了。"
    blank
    note "（同時跑兩份會互相搶記憶體，反而兩邊都變慢，所以先擋下來）"
    alert "已經有一份在轉錄中" "電腦正在處理另一個錄音檔，請等那個視窗跑完，再回來執行一次。"
    pause_close
    exit 0
  fi
  rm -rf "$LOCK_DIR" 2>/dev/null
  mkdir "$LOCK_DIR" 2>/dev/null || true
fi
echo "$$" > "$LOCK_DIR/pid" 2>/dev/null
ps -p $$ -o lstart= 2>/dev/null > "$LOCK_DIR/start"
# 正常結束、按 Ctrl-C、或直接把視窗關掉，都要記得把鎖拿掉
unlock() { rm -rf "$LOCK_DIR" 2>/dev/null; }
trap unlock EXIT
trap 'unlock; exit 130' INT
trap 'unlock; exit 143' TERM HUP

# --- 選檔案 ---------------------------------------------------------------
clear
banner "📝  會議逐字稿"
say "請稍等幾秒，等一下會自動跳出「選擇錄音檔」的視窗。"
blank
warn "視窗跳出來以後，再挑要轉成逐字稿的錄音檔就可以了。"
blank
note "（如果沒有馬上看到，可能被這個視窗擋住了，"
note "  也可能縮在螢幕下方的 Dock，稍等一下就會出現）"
blank

AUDIO=$(osascript <<'EOF' 2>/dev/null
set theFile to choose file with prompt "請選擇要轉成逐字稿的錄音檔" of type ¬
    {"m4a", "mp3", "wav", "aac", "mp4", "mov", "caf", "aiff", "flac", "ogg", "wma"}
POSIX path of theFile
EOF
)

if [ -z "${AUDIO:-}" ]; then
  exit 0   # 使用者按了取消
fi

mkdir -p "$OUT_DIR" "$LOG_DIR"
clear
title_bar "會議逐字稿（處理中）"
banner "⏳  正在產生逐字稿" "$PINK"
printf '%s   錄音檔：%s%s%s\n' "$D$GREY" "$R$B" "$(basename "$AUDIO")" "$R"
blank
say "接下來請放著等就好，不用做任何事。"
blank
item "這個視窗會慢慢出現幾行進度文字，那是正常的。"
item "${D}不用去拉大或縮小視窗，字不會很多，這樣看剛剛好。${R}"
item "中途請${B}不要關掉${R}這個視窗。"
item "跑完會${GREEN}自動幫你打開逐字稿${R}，不用自己去找。"
blank
note "（等待時電腦可以照常做別的事，只是會比較慢）"
printf '%s%s%s\n' "$GREY" "$LINE" "$R"
blank

# 每次執行各自一份紀錄，兩個視窗就算真的同時跑也不會互相蓋掉
LOG="$LOG_DIR/執行紀錄_$$.txt"
ERRLOG="$LOG_DIR/錯誤訊息_$$.txt"
# 只留最近 20 份，免得長年累積
ls -t "$LOG_DIR"/*.txt 2>/dev/null | tail -n +21 | while read -r f; do rm -f "$f"; done
# 舊版把紀錄檔丟在「逐字稿」資料夾裡，現在改放系統資料夾，順手清掉
rm -f "$OUT_DIR/.最近一次執行紀錄.txt" "$OUT_DIR/.最近一次錯誤訊息.txt" 2>/dev/null

# 進度走 stdout（即時顯示在畫面上），雜訊走 stderr（只寫進檔案）。
# 這樣 objc 那種嚇人的警告不會洗版，但出事時仍然查得到。
# 注意：這裡不能用 grep 過濾，grep 會把輸出攢成一大塊才吐出來，
# 畫面就會整段空白、看起來像當機。
"$VENV/bin/python" -u "$HERE/bin/transcribe.py" "$AUDIO" "$OUT_DIR" 2>"$ERRLOG" | tee "$LOG"
STATUS=${PIPESTATUS[0]}

RESULT=$(grep '^__OUTPUT__' "$LOG" | tail -1 | sed 's/^__OUTPUT__//')

blank
if [ "$STATUS" -eq 0 ] && [ -n "$RESULT" ] && [ -f "$RESULT" ]; then
  title_bar "會議逐字稿（完成）"
  banner "✅  完成了！" "$GREEN"
  say "逐字稿已經自動打開，也存在下面這個資料夾裡："
  printf '%s   %s%s\n' "$CYAN" "$OUT_DIR" "$R"
  blank
  note "（這個視窗可以關掉了）"
  osascript -e 'display notification "逐字稿已經完成" with title "會議逐字稿"' >/dev/null 2>&1
  open "$RESULT"
  open "$OUT_DIR"
else
  title_bar "會議逐字稿（失敗）"
  banner "⚠️  出了點問題，沒有產生逐字稿" "$RED"
  warn "錯誤訊息如下："
  printf '%s%s%s\n' "$GREY" "$LINE" "$R"
  tail -25 "$ERRLOG" 2>/dev/null
  printf '%s%s%s\n' "$GREY" "$LINE" "$R"
  blank
  say "請把這個視窗${B}整個截圖${R}，傳給幫你安裝的人看一下。"
  alert "轉錄失敗" "沒有順利產生逐字稿。請把終端機視窗截圖傳給幫你安裝的人。"
fi

pause_close

# 明確在這裡結束，bash 就不會再回頭去讀檔案剩下的部分
exit 0

}   # ←（對應開頭那個「先整段讀完再執行」的大括號）
