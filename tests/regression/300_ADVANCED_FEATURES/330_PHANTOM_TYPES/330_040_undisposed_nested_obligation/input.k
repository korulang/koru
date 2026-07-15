import app/fs
app/fs:open(path: "test.txt"): f |> app/fs:read(f.file): d |> app/fs:close(d.file)
