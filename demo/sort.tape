# --sort --human keeps the largest lines of the whole stream, not the last ones.
# pv paces du's output so the window can be seen reordering as entries arrive.
Output .frames/
Source ../prelude.tape

Type "du -sh tree/* | pv -qL 60 | scroll --null --sort --human -12"
Sleep 1s
Enter
Sleep 14s
