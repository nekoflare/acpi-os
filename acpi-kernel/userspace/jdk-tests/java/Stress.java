// E3: a multithreaded, allocation-heavy program that checks its own results.
// Workers build linked lists, hash maps, sorted arrays and large arrays and
// keep some of them alive long enough to reach the old generation; every
// structure is verified when it is built and again when it is dropped, so a
// collector or memory-management bug shows up as a checksum mismatch. Other
// threads exercise blocking queues, monitors, ReentrantLock, wait/notify,
// thread creation, the ForkJoin pool and CompletableFuture.
//   java Stress.java <seconds>
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.TreeMap;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.LongAdder;
import java.util.concurrent.locks.ReentrantLock;
import java.util.stream.IntStream;

public class Stress {
    static volatile boolean failed;
    static volatile long deadline;
    static final LongAdder rounds = new LongAdder();
    static final LongAdder bigArrays = new LongAdder();
    static final ConcurrentHashMap<String, LongAdder> events = new ConcurrentHashMap<>();

    static void fail(String message) {
        failed = true;
        System.out.println("FAIL " + message);
    }

    static boolean running() {
        return !failed && System.nanoTime() < deadline;
    }

    static void count(String event) {
        events.computeIfAbsent(event, k -> new LongAdder()).increment();
    }

    static final class Node {
        final long value;
        final Node next;
        final byte[] pad;

        Node(long value, Node next, int padSize) {
            this.value = value;
            this.next = next;
            this.pad = new byte[padSize];
            Arrays.fill(pad, (byte) value);
        }
    }

    // A list kept alive across many collections, with what it should hold.
    record Retained(Node head, long sum, int count) {
        void verify(String where) {
            long got = 0;
            int n = 0;
            for (Node p = head; p != null; p = p.next) {
                got += p.value;
                n++;
                for (byte b : p.pad) {
                    if (b != (byte) p.value) {
                        fail(where + ": node padding changed");
                        return;
                    }
                }
            }
            if (got != sum || n != count) {
                fail(where + ": retained list sum " + got + "/" + sum + " count " + n + "/" + count);
            }
        }
    }

    static void workRound(int worker, long round, Retained[] retained) {
        Random random = new Random(worker * 1_000_003L + round);

        // A linked list of small objects, summed while built and after.
        int n = 1_000 + random.nextInt(14_000);
        Node head = null;
        long sum = 0;
        for (int i = 0; i < n; i++) {
            long v = random.nextLong();
            sum += v;
            head = new Node(v, head, random.nextInt(48));
        }
        Retained list = new Retained(head, sum, n);
        list.verify("worker " + worker + " new list");

        // Keep it in place of an older list, which is checked as it goes.
        int slot = random.nextInt(retained.length);
        if (retained[slot] != null) {
            retained[slot].verify("worker " + worker + " old list");
        }
        retained[slot] = list;

        // A hash map with string keys.
        Map<String, Integer> map = new HashMap<>();
        int inserts = 5_000;
        for (int i = 0; i < inserts; i++) {
            map.merge("key-" + random.nextInt(2_000), 1, Integer::sum);
        }
        int total = 0;
        for (int value : map.values()) {
            total += value;
        }
        if (total != inserts) {
            fail("worker " + worker + " map total " + total);
        }

        // Sorting keeps the multiset of values.
        int[] values = random.ints(10_000).toArray();
        long before = 0;
        for (int v : values) {
            before += v;
        }
        Arrays.sort(values);
        long after = values[0];
        for (int i = 1; i < values.length; i++) {
            if (values[i - 1] > values[i]) {
                fail("worker " + worker + " not sorted");
                break;
            }
            after += values[i];
        }
        if (before != after) {
            fail("worker " + worker + " sort sum");
        }

        // A tree map of boxed longs.
        TreeMap<Long, String> tree = new TreeMap<>();
        for (int i = 0; i < 3_000; i++) {
            long key = random.nextInt(1_000_000);
            tree.put(key, Long.toHexString(key));
        }
        long previous = -1;
        for (Map.Entry<Long, String> entry : tree.entrySet()) {
            if (entry.getKey() <= previous || Long.parseLong(entry.getValue(), 16) != entry.getKey()) {
                fail("worker " + worker + " tree order");
                break;
            }
            previous = entry.getKey();
        }

        // Now and then an array of a megabyte or more (a humongous object
        // for G1), filled and checked at both ends.
        if (random.nextInt(8) == 0) {
            byte[] big = new byte[(1 << 20) + random.nextInt(3 << 20)];
            byte mark = (byte) round;
            Arrays.fill(big, mark);
            if (big[0] != mark || big[big.length / 2] != mark || big[big.length - 1] != mark) {
                fail("worker " + worker + " big array");
            }
            bigArrays.increment();
        }
        rounds.increment();
    }

    static Thread start(String name, Runnable body) {
        Thread thread = new Thread(() -> {
            try {
                body.run();
            } catch (Throwable t) {
                fail(name + " threw " + t);
                t.printStackTrace(System.out);
            }
        }, name);
        thread.start();
        return thread;
    }

    public static void main(String[] args) throws Exception {
        int seconds = args.length > 0 ? Integer.parseInt(args[0]) : 60;
        long start = System.nanoTime();
        deadline = start + seconds * 1_000_000_000L;
        int cpus = Runtime.getRuntime().availableProcessors();
        int workers = Math.min(8, Math.max(4, 2 * cpus));
        System.out.println("stress: " + seconds + " s, " + cpus + " CPUs, " + workers + " workers, vm "
                + System.getProperty("java.vm.name") + ", max heap "
                + Runtime.getRuntime().maxMemory() / (1 << 20) + " MiB");
        List<Thread> threads = new ArrayList<>();

        for (int w = 0; w < workers; w++) {
            int worker = w;
            threads.add(start("worker-" + w, () -> {
                Retained[] retained = new Retained[12];
                for (long round = 0; running(); round++) {
                    workRound(worker, round, retained);
                }
                for (Retained r : retained) {
                    if (r != null) {
                        r.verify("worker " + worker + " final");
                    }
                }
            }));
        }

        // Producer and consumer through a small blocking queue.
        BlockingQueue<Long> queue = new ArrayBlockingQueue<>(64);
        AtomicLong produced = new AtomicLong();
        AtomicLong consumedSum = new AtomicLong();
        threads.add(start("producer", () -> {
            long i = 0;
            try {
                while (running()) {
                    queue.put(i++);
                }
                queue.put(-1L);
            } catch (InterruptedException e) {
                throw new RuntimeException(e);
            }
            produced.set(i);
        }));
        threads.add(start("consumer", () -> {
            long s = 0;
            try {
                for (long v; (v = queue.take()) >= 0; ) {
                    s += v;
                }
            } catch (InterruptedException e) {
                throw new RuntimeException(e);
            }
            consumedSum.set(s);
        }));

        // Monitor and ReentrantLock contention on shared counters.
        Object monitor = new Object();
        ReentrantLock lock = new ReentrantLock();
        long[] monitorCount = {0};
        long[] lockCount = {0};
        LongAdder lockedIncrements = new LongAdder();
        for (int c = 0; c < 4; c++) {
            threads.add(start("contender-" + c, () -> {
                long mine = 0;
                while (running()) {
                    for (int i = 0; i < 1_000; i++) {
                        synchronized (monitor) {
                            monitorCount[0]++;
                        }
                        lock.lock();
                        try {
                            lockCount[0]++;
                        } finally {
                            lock.unlock();
                        }
                        mine++;
                    }
                }
                lockedIncrements.add(mine);
            }));
        }

        // wait/notify ping-pong.
        Object ball = new Object();
        long[] hits = {0};
        for (int p = 0; p < 2; p++) {
            int parity = p;
            threads.add(start("ping-" + p, () -> {
                synchronized (ball) {
                    while (true) {
                        while (hits[0] % 2 != parity && hits[0] >= 0) {
                            try {
                                ball.wait(100);
                            } catch (InterruptedException e) {
                                throw new RuntimeException(e);
                            }
                            if (!running()) {
                                hits[0] = -1;
                            }
                        }
                        if (hits[0] < 0) {
                            ball.notifyAll();
                            return;
                        }
                        hits[0]++;
                        count("ping-pong");
                        ball.notifyAll();
                    }
                }
            }));
        }

        // Short-lived threads, created and joined in batches.
        threads.add(start("spawner", () -> {
            while (running()) {
                Thread[] batch = new Thread[8];
                long[] results = new long[batch.length];
                for (int i = 0; i < batch.length; i++) {
                    int index = i;
                    batch[i] = new Thread(() -> {
                        long s = 0;
                        for (int k = 0; k <= 10_000; k++) {
                            s += k;
                        }
                        results[index] = s;
                    });
                    batch[i].start();
                }
                for (int i = 0; i < batch.length; i++) {
                    try {
                        batch[i].join();
                    } catch (InterruptedException e) {
                        throw new RuntimeException(e);
                    }
                    if (results[i] != 50_005_000L) {
                        fail("spawned thread result " + results[i]);
                    }
                    count("threads spawned");
                }
            }
        }));

        // Parallel streams on the common ForkJoin pool.
        threads.add(start("streams", () -> {
            while (running()) {
                long s = IntStream.range(0, 1_000_000).parallel().mapToLong(i -> (long) i * i % 1_000).sum();
                long expect = 0;
                for (int i = 0; i < 1_000_000; i++) {
                    expect += (long) i * i % 1_000;
                }
                if (s != expect) {
                    fail("parallel stream " + s + " != " + expect);
                }
                count("parallel streams");
            }
        }));

        // CompletableFuture chains on a fixed pool.
        ExecutorService pool = Executors.newFixedThreadPool(4);
        threads.add(start("futures", () -> {
            while (running()) {
                List<CompletableFuture<Long>> futures = new ArrayList<>();
                for (int i = 0; i < 64; i++) {
                    long base = i;
                    futures.add(CompletableFuture.supplyAsync(() -> base * 3, pool)
                            .thenApplyAsync(v -> v + 1, pool)
                            .thenCombine(CompletableFuture.supplyAsync(() -> base, pool), Long::sum));
                }
                long s = 0;
                for (CompletableFuture<Long> f : futures) {
                    s += f.join();
                }
                // sum over i of 4i + 1
                if (s != 4 * (63 * 64 / 2) + 64) {
                    fail("futures sum " + s);
                }
                count("future batches");
            }
        }));

        // Progress once every ten seconds.
        long nextReport = start + 10_000_000_000L;
        while (System.nanoTime() < deadline && !failed) {
            Thread.sleep(200);
            if (System.nanoTime() >= nextReport) {
                nextReport += 10_000_000_000L;
                Runtime rt = Runtime.getRuntime();
                System.out.println("  " + (System.nanoTime() - start) / 1_000_000_000L + " s: rounds "
                        + rounds.sum() + ", heap used " + (rt.totalMemory() - rt.freeMemory()) / (1 << 20)
                        + " MiB, " + gcSummary());
            }
        }

        for (Thread thread : threads) {
            thread.join(60_000);
            if (thread.isAlive()) {
                fail(thread.getName() + " did not finish");
                for (StackTraceElement e : thread.getStackTrace()) {
                    System.out.println("    at " + e);
                }
            }
        }
        pool.shutdown();
        if (!pool.awaitTermination(10, TimeUnit.SECONDS)) {
            fail("pool did not stop");
        }

        long n = produced.get();
        if (consumedSum.get() != n * (n - 1) / 2) {
            fail("queue sum " + consumedSum.get() + " for " + n + " items");
        }
        if (monitorCount[0] != lockedIncrements.sum() || lockCount[0] != lockedIncrements.sum()) {
            fail("lost increments: monitor " + monitorCount[0] + " lock " + lockCount[0] + " expected "
                    + lockedIncrements.sum());
        }
        System.out.println("rounds " + rounds.sum() + ", big arrays " + bigArrays.sum() + ", queue items " + n
                + ", locked increments " + lockedIncrements.sum());
        events.forEach((k, v) -> System.out.println(k + " " + v.sum()));
        System.out.println(gcSummary());
        if (failed) {
            System.exit(1);
        }
        System.out.println("STRESS OK in " + (System.nanoTime() - start) / 1_000_000 + " ms");
    }

    static String gcSummary() {
        StringBuilder sb = new StringBuilder();
        for (GarbageCollectorMXBean gc : ManagementFactory.getGarbageCollectorMXBeans()) {
            if (sb.length() > 0) {
                sb.append(", ");
            }
            sb.append(gc.getName()).append(' ').append(gc.getCollectionCount()).append(" in ")
                    .append(gc.getCollectionTime()).append(" ms");
        }
        return sb.toString();
    }
}
