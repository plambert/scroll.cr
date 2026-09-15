# --fullscreen uses the alternate screen and leaves nothing behind; --leave
# keeps the last -N lines on the main screen on the way out.
Output .frames/
Source ../prelude.tape

Type "fake-build 70 6 | scroll --fullscreen --leave -8 > build.log"
Sleep 1s
Enter
Sleep 10s
Sleep 2500ms
