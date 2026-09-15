# Prints the grid the prelude's pixel size produces, into demo/out/grid.txt.
# Adjust Width and Height there until it reads "30 100".
Output .frames/
Source ../prelude.tape

Type "stty size | tee ../out/grid.txt"
Enter
Sleep 2s
