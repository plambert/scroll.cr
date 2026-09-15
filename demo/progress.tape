# --progress with a known size: percentage, bar, ETA, rates, and a label.
Output .frames/
Source ../prelude.tape

Type "pv -qL 500k big.log | scroll --size 6M --name big.log -14 > /dev/null"
Sleep 1s
Enter
Sleep 13500ms
