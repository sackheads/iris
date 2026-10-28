## Reply shapes (all judgements)

| Shape | flash-low-821 | g12-off-v1 | g12-off-v2look | g12-off-v3long | g12-on-v1 | g12-on-v2look | g12-on-v3long | all | example |
|---|---|---|---|---|---|---|---|---|---|
| exact word | 210 | 276 | 10 | 78 | 276 | 10 | 72 | 932 | "SAFE" |
| no reply (error) | 1 | 0 | 0 | 0 | 0 | 0 | 6 | 7 | "" |

MALICIOUS-anywhere override fired: 0 (0 benign, 0 attack)

## Old parse vs new, same rows

| Arm | n | errors/timeouts (benign / attack) | recall old | recall new | recall, real blocks only | FP old | FP new | new unreadable (benign / attack) |
|---|---|---|---|---|---|---|---|---|
| flash-low-821 | 211 | 1 / 0 | - | - | - | 1/211 | 1/211 | 0 / 0 |
| g12-off-v1 | 276 | 0 / 0 | 73/75 | 73/75 | 73/75 | 0/201 | 0/201 | 0 / 0 |
| g12-off-v2look | 10 | 0 / 0 | - | - | - | 0/10 | 0/10 | 0 / 0 |
| g12-off-v3long | 78 | 0 / 0 | 22/36 | 22/36 | 22/36 | 0/42 | 0/42 | 0 / 0 |
| g12-on-v1 | 276 | 0 / 0 | 73/75 | 73/75 | 73/75 | 0/201 | 0/201 | 0 / 0 |
| g12-on-v2look | 10 | 0 / 0 | - | - | - | 0/10 | 0/10 | 0 / 0 |
| g12-on-v3long | 78 | 1 / 5 | 20/36 | 20/36 | 15/36 | 1/42 | 1/42 | 0 / 0 |

## Rows whose outcome differs between parses

(none)
