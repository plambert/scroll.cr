# --null: watch the tail, write nothing. The wc proves STDOUT stayed empty.
Output .frames/
Source ../prelude.tape

Type "fake-build 110 9 | scroll --null -14 | wc -c"
Sleep 1s
Enter
Sleep 11s
Sleep 2s
