#!/bin/sh
# Exercise sqlite3 against the kernel's file, locking, and process APIs.
#
#   sqlite3-test [parent-dir]
#
# Work happens in a fresh parent-dir/sqlite3-test.PID directory (default
# parent: /, the ext4 root) that is removed afterwards.
#
# Environment: ROWS (bulk rows, default 20000), WORKERS (concurrent
# processes, default 4), PER (transactions per worker, default 100),
# KEEP=1 keeps the work directory for inspection.
set -u

SQLITE=${SQLITE:-sqlite3}
DIR=${1:-}/sqlite3-test.$$
ROWS=${ROWS:-20000}
WORKERS=${WORKERS:-4}
PER=${PER:-100}
pass=0
fail=0
start=$(date +%s)

ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad()
{
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$1"
    if [ $# -gt 1 ]; then printf '      %s\n' "$2" | head -c 600; printf '\n'; fi
}
# check NAME EXPECTED ACTUAL
check()
{
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
# contains NAME NEEDLE ACTUAL
contains()
{
    case $3 in *"$2"*) ok "$1" ;; *) bad "$1" "expected output containing [$2] got [$3]" ;; esac
}
sq() { "$SQLITE" -batch "$@" 2>&1; }
size() { wc -c < "$1" | tr -d ' '; }
section() { printf '\n== %s\n' "$1"; }

rm -rf "$DIR"
mkdir -p "$DIR" || { echo "cannot create $DIR"; exit 1; }
cd "$DIR" || exit 1
# Keep sqlite's anonymous temp files on the ext4 volume under test.
SQLITE_TMPDIR=$DIR
export SQLITE_TMPDIR

section "build and in-memory engine"
v=$(sq -version)
case $v in 3.*) ok "sqlite3 runs: $v" ;; *) bad "sqlite3 runs" "$v" ;; esac
check "arithmetic" 42 "$(sq :memory: 'SELECT 6*7;')"
check "recursive CTE, 100k rows" 5000050000 "$(sq :memory: \
    'WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<100000) SELECT sum(x) FROM c;')"
check "json" 3 "$(sq :memory: "SELECT json_extract('{\"a\":[1,2,3]}', '\$.a[2]');")"
check "fts5" 1 "$(sq :memory: <<'SQL'
CREATE VIRTUAL TABLE t USING fts5(x);
INSERT INTO t VALUES ('the quick brown fox'), ('lazy dog');
SELECT count(*) FROM t WHERE t MATCH 'fox';
SQL
)"
check "rtree" 1 "$(sq :memory: <<'SQL'
CREATE VIRTUAL TABLE r USING rtree(id, x0, x1);
INSERT INTO r VALUES (1, 0, 10), (2, 20, 30);
SELECT id FROM r WHERE x0 <= 5 AND x1 >= 5;
SQL
)"
check "math functions" 1414.0 "$(sq :memory: 'SELECT round(sqrt(2)*1000);')"
check "randomness and clock" "16|real|1" "$(sq :memory: \
    "SELECT length(randomblob(16)), typeof(julianday('now')), julianday('now') > 2460000;")"

section "file database: open, pwrite64, pread64, fsync, unlink"
out=$(sq basic.db <<'SQL'
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t(v) VALUES ('alpha'), ('beta'), ('gamma');
SELECT group_concat(v, ',') FROM t;
SQL
)
check "create and query" "alpha,beta,gamma" "$out"
check "reopen in a new process" 3 "$(sq basic.db 'SELECT count(*) FROM t;')"
check "integrity_check" ok "$(sq basic.db 'PRAGMA integrity_check;')"
check "file size matches page count" "$(sq basic.db 'SELECT page_count*page_size FROM pragma_page_count, pragma_page_size;')" "$(size basic.db)"
[ ! -e basic.db-journal ] && ok "rollback journal deleted after commit" || bad "rollback journal deleted after commit"
check "rollback discards changes" 3 "$(sq basic.db <<'SQL'
BEGIN;
INSERT INTO t(v) VALUES ('discarded');
DELETE FROM t WHERE id = 1;
ROLLBACK;
SELECT count(*) FROM t;
SQL
)"

section "journal modes"
for mode in delete truncate persist memory; do
    out=$(sq "j_$mode.db" <<SQL
CREATE TABLE t(id INTEGER PRIMARY KEY, b BLOB);
PRAGMA journal_mode=$mode;
BEGIN;
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<500)
INSERT INTO t(b) SELECT randomblob(300) FROM c;
COMMIT;
UPDATE t SET b = randomblob(200) WHERE id % 3 = 0;
DELETE FROM t WHERE id % 5 = 0;
SELECT count(*) FROM t;
PRAGMA integrity_check;
SQL
)
    check "journal_mode=$mode" "$mode
400
ok" "$out"
done
if [ -f j_truncate.db-journal ] && [ "$(size j_truncate.db-journal)" = 0 ]; then
    ok "truncate mode leaves an empty journal (ftruncate)"
else
    bad "truncate mode leaves an empty journal (ftruncate)" "$(ls -l j_truncate.db-journal 2>&1)"
fi
[ -f j_persist.db-journal ] && ok "persist mode keeps its journal" || bad "persist mode keeps its journal"

section "bulk stress: $ROWS rows, updates, deletes, VACUUM"
t0=$(date +%s)
out=$(sq big.db <<SQL
CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER, b BLOB);
CREATE INDEX t_n ON t(n);
BEGIN;
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<$ROWS)
INSERT INTO t(n, b) SELECT abs(random()) % 1000, randomblob(100 + abs(random()) % 300) FROM c;
COMMIT;
SELECT count(*) FROM t;
SQL
)
check "insert $ROWS rows in one transaction" "$ROWS" "$out"
i=0
while [ $i -lt 10 ]; do
    sq big.db "UPDATE t SET n = n + 1, b = randomblob(50) WHERE id % 10 = $i;" > /dev/null
    i=$((i + 1))
done
check "10 update transactions" "$ROWS" "$(sq big.db 'SELECT count(*) FROM t WHERE length(b) = 50;')"
half=$(sq big.db 'DELETE FROM t WHERE id % 2 = 0; SELECT count(*) FROM t;')
check "delete half" $((ROWS - ROWS / 2)) "$half"
before=$(size big.db)
check "VACUUM" "" "$(sq big.db 'VACUUM;')"
after=$(size big.db)
if [ "$after" -lt "$before" ]; then ok "VACUUM shrank the file ($before -> $after bytes)"
else bad "VACUUM shrank the file" "$before -> $after bytes"; fi
check "integrity after VACUUM" ok "$(sq big.db 'PRAGMA integrity_check;')"
check "file size matches page count after VACUUM" "$(sq big.db 'SELECT page_count*page_size FROM pragma_page_count, pragma_page_size;')" "$after"
printf '      bulk section took %ss\n' $(($(date +%s) - t0))

section "auto_vacuum=incremental (ftruncate shrink)"
out=$(sq inc.db <<'SQL'
PRAGMA auto_vacuum=INCREMENTAL;
CREATE TABLE t(b BLOB);
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<2000)
INSERT INTO t SELECT randomblob(1000) FROM c;
SQL
)
before=$(size inc.db)
sq inc.db 'DELETE FROM t; PRAGMA incremental_vacuum;' > /dev/null
out=$(sq inc.db 'PRAGMA freelist_count; PRAGMA integrity_check;')
after=$(size inc.db)
check "incremental_vacuum empties the freelist" "0
ok" "$out"
if [ "$after" -lt "$before" ]; then ok "incremental_vacuum shrank the file ($before -> $after bytes)"
else bad "incremental_vacuum shrank the file" "$before -> $after bytes"; fi

section "temp files (opened, unlinked, grown, truncated)"
out=$(sq big.db <<'SQL'
PRAGMA temp_store=FILE;
PRAGMA cache_size=-64;
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<50000)
SELECT count(*) FROM (SELECT x, randomblob(64) AS r FROM c ORDER BY r);
CREATE TEMP TABLE tt AS SELECT * FROM t;
SELECT (SELECT count(*) FROM tt) = (SELECT count(*) FROM main.t);
SQL
)
check "external sort and temp table" "50000
1" "$out"

section "dump, reload, and online backup"
digest=$(sq big.db "SELECT hex(sha3_query('SELECT * FROM t ORDER BY id'));")
sq big.db .dump > dump.sql
sq copy.db < dump.sql > /dev/null
check ".dump round trip" "$digest" "$(sq copy.db "SELECT hex(sha3_query('SELECT * FROM t ORDER BY id'));")"
sq big.db ".backup backup.db" > /dev/null
check ".backup copy" "$digest" "$(sq backup.db "SELECT hex(sha3_query('SELECT * FROM t ORDER BY id'));")"
check "mmap_size reads" "$digest" "$(sq big.db "PRAGMA mmap_size=16777216; SELECT hex(sha3_query('SELECT * FROM t ORDER BY id'));" | tail -n 1)"
out=$(sq blob.db "CREATE TABLE b(x); INSERT INTO b VALUES (randomblob(3000000)); SELECT length(x) FROM b;")
check "3 MB blob" 3000000 "$out"
check "3 MB blob after reopen" "ok
3000000" "$(sq blob.db 'PRAGMA integrity_check; SELECT length(x) FROM b;')"

section "POSIX record locks between processes (fcntl F_SETLK)"
sq lock.db 'CREATE TABLE t(v); CREATE TABLE c(n); INSERT INTO c VALUES (0);' > /dev/null
( printf 'BEGIN EXCLUSIVE;\nINSERT INTO t VALUES (1);\n'; sleep 4; printf 'COMMIT;\n' ) |
    "$SQLITE" -batch lock.db > holder.out 2>&1 &
holder=$!
sleep 2
contains "EXCLUSIVE lock blocks another writer" "database is locked" "$(sq lock.db 'INSERT INTO t VALUES (2);')"
contains "EXCLUSIVE lock blocks another reader" "database is locked" "$(sq lock.db 'SELECT count(*) FROM t;')"
wait $holder
check "holder committed, blocked writer did not" "1" "$(sq lock.db 'SELECT count(*) FROM t;')"

( printf 'BEGIN;\nSELECT count(*) FROM t;\n'; sleep 4; printf 'COMMIT;\n' ) |
    "$SQLITE" -batch lock.db > holder.out 2>&1 &
holder=$!
sleep 2
check "SHARED lock admits another reader" 1 "$(sq lock.db 'SELECT count(*) FROM t;')"
contains "SHARED lock blocks a writer's commit" "database is locked" "$(sq lock.db 'INSERT INTO t VALUES (3);')"
wait $holder

( printf 'BEGIN EXCLUSIVE;\nINSERT INTO t VALUES (4);\n'; sleep 3; printf 'COMMIT;\n' ) |
    "$SQLITE" -batch lock.db > holder.out 2>&1 &
holder=$!
sleep 1
check "busy_timeout waits for the lock (nanosleep)" "" "$(sq lock.db '.timeout 15000' 'INSERT INTO t VALUES (5);')"
wait $holder
check "both writers committed" "1,4,5" "$(sq lock.db "SELECT group_concat(v, ',') FROM (SELECT v FROM t ORDER BY v);")"

( printf 'BEGIN EXCLUSIVE;\nINSERT INTO t VALUES (99);\nUPDATE c SET n = -1;\n'; sleep 5 ) |
    "$SQLITE" -batch lock.db > holder.out 2>&1 &
holder=$!
sleep 2
[ -e lock.db-journal ] && ok "killed holder left a hot journal" || bad "killed holder left a hot journal"
kill -9 $holder 2>/dev/null
wait $holder 2>/dev/null
check "lock released when the holder is killed" "" "$(sq lock.db 'INSERT INTO t VALUES (6);')"
check "hot journal rolled back" "0|0|ok" "$(sq lock.db "SELECT (SELECT count(*) FROM t WHERE v = 99), (SELECT n FROM c), (SELECT integrity_check FROM pragma_integrity_check);")"

section "concurrent writers: $WORKERS processes x $PER transactions"
t0=$(date +%s)
w=1
while [ $w -le $WORKERS ]; do
    {
        echo '.timeout 60000'
        n=1
        while [ $n -le $PER ]; do
            echo "BEGIN IMMEDIATE; UPDATE c SET n = n + 1; INSERT INTO t VALUES ($((w * 100000 + n))); COMMIT;"
            n=$((n + 1))
        done
    } > "worker$w.sql"
    w=$((w + 1))
done
sq lock.db 'UPDATE c SET n = 0; DELETE FROM t;' > /dev/null
pids=
w=1
while [ $w -le $WORKERS ]; do
    "$SQLITE" -batch lock.db < "worker$w.sql" > "worker$w.out" 2>&1 &
    pids="$pids $!"
    w=$((w + 1))
done
r=1
while [ $r -le 2 ]; do
    ( i=0; while [ $i -lt 40 ]; do "$SQLITE" -batch lock.db '.timeout 60000' 'SELECT count(*) FROM t;' > /dev/null 2>> "reader$r.out"; i=$((i + 1)); done ) &
    pids="$pids $!"
    r=$((r + 1))
done
for pid in $pids; do wait "$pid"; done
errors=$(cat worker*.out reader*.out 2>/dev/null)
check "workers reported no errors" "" "$errors"
total=$((WORKERS * PER))
check "no lost updates (counter = $total)" "$total" "$(sq lock.db 'SELECT n FROM c;')"
check "every insert committed" "$total" "$(sq lock.db 'SELECT count(*) FROM t;')"
check "integrity after contention" ok "$(sq lock.db 'PRAGMA integrity_check;')"
printf '      concurrency section took %ss\n' $(($(date +%s) - t0))

section "WAL"
out=$(sq walx.db <<'SQL'
PRAGMA locking_mode=EXCLUSIVE;
PRAGMA journal_mode=WAL;
CREATE TABLE t(b);
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<1000)
INSERT INTO t SELECT randomblob(200) FROM c;
PRAGMA wal_checkpoint(TRUNCATE);
SQL
)
case $out in
    "exclusive
wal
0|"*) ok "WAL with locking_mode=EXCLUSIVE (no shared memory)" ;;
    *) bad "WAL with locking_mode=EXCLUSIVE (no shared memory)" "$out" ;;
esac
check "WAL database after reopen" "1000|ok" "$(sq walx.db 'SELECT count(*), (SELECT integrity_check FROM pragma_integrity_check) FROM t;')"
out=$(sq wal.db 'PRAGMA journal_mode=WAL; CREATE TABLE t(v); INSERT INTO t VALUES (1); SELECT count(*) FROM t;')
if [ "$out" = "wal
1" ] && [ "$(sq wal.db 'SELECT count(*) FROM t;')" = 1 ]; then
    ok "shared-memory WAL (MAP_SHARED mmap of the -shm file)"
else
    bad "shared-memory WAL (MAP_SHARED mmap of the -shm file)" "$out"
fi

cd / || exit 1
if [ "${KEEP:-0}" = 1 ]; then printf '\nKept %s\n' "$DIR"; else rm -rf "$DIR"; fi
printf '\n%d passed, %d failed in %ss\n' "$pass" "$fail" $(($(date +%s) - start))
[ "$fail" -eq 0 ]
