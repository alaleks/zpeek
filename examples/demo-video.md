# zpeek demo · 40 seconds

The [VHS tape](demo.tape) renders the roughly 31-second terminal segment for 5–36s. Record the first and last shots in Zed with its integrated terminal, then cut to the terminal segment. Both `dev` and `prod` are local, read-only SQLite demos; no production database is used.

| Time | Shot |
| --- | --- |
| 0–5s | Show `examples/demo.sql` in Zed. Open the integrated terminal and launch `./zig-out/bin/zpeek --config examples/demo.toml`. |
| 5–12s | Run `/tables`, choose `orders`, and hold on the data grid. The green `dev` badge stays visible. |
| 12–22s | Move to `customer_id`, press `f`, select the related customer's name, open its full value with `enter`, then return to the FK preview. |
| 22–30s | Type `SELECT * FROM ord`, pause on autocomplete, accept `orders`, add `WHERE total_usd >= 100;`, and show the result. |
| 30–36s | Run `/connect`, show both saved profiles, choose `prod`, and hold on the orange `prod` badge. |
| 36–40s | Close the integrated terminal panel so the editor is visible again. |

Prepare the local data before recording the Zed shots:

```sh
zig build -Doptimize=ReleaseSafe
mkdir -p .zig-cache/demo
sqlite3 .zig-cache/demo/dev.db < examples/demo.sql
sqlite3 .zig-cache/demo/prod.db < examples/demo.sql
```

Regenerate the terminal clip with `vhs examples/demo.tape`. The tape prepares its own demo databases, so it can run independently of the Zed shots.
