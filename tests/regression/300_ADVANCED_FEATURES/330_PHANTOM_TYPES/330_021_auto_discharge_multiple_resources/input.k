import app/fs
app/fs:open(path: "first.txt"): _ |> app/fs:open(path: "second.txt"): f2 |> app/fs:close(file: f2)
