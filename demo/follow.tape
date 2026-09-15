# -f follows like `tail -F`, and opens on the lines already in the file.
Output .frames/
Source ../prelude.tape

Hide
Type "writer app.log 400 6 &"
Enter
Type "clear"
Enter
Show

Type "scroll -f app.log --name app.log -14"
Sleep 1s
Enter
Sleep 12s
Ctrl+C
Sleep 1s
