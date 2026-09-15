# The whole idea: the stream keeps flowing to STDOUT while the tail is watched.
Output .frames/
Source ../prelude.tape

Type "fake-build 110 9 | scroll -14 > build.log"
Sleep 1s
Enter
Sleep 11s
Type "wc -l build.log"
Enter
Sleep 2500ms
