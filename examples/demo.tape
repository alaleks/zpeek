Output examples/demo.gif

Require sqlite3

Set Shell "bash"
Set FontSize 18
Set Width 1180
Set Height 680
Set Framerate 12
Set TypingSpeed 25ms
Set Theme "Catppuccin Mocha"

Hide
Type "sqlite3 /tmp/zpeek-demo.db < examples/demo.sql"
Enter
Type "unset NO_COLOR"
Enter
Show

Type "ZPEEK_CONFIG=/dev/null ./zig-out/bin/zpeek"
Enter
Sleep 1s

Type "/connect /tmp/zpeek-demo.db"
Enter
Sleep 1s

Type "/tables"
Enter
Sleep 1s

Type "select * from orders"
Enter
Sleep 2s

Type "/browse orders"
Enter
Sleep 3s
Down 2
Right 3
Sleep 1s

Type "/"
Type "total_usd >= 100"
Enter
Sleep 3s

Type "t"
Sleep 2s
Type "s"
Sleep 2s
Enter
Sleep 2s
Escape
Sleep 1s
Type "q"
Ctrl+D
