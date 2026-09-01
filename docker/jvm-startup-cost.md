# JVM startup cost in the traffic-light

What a java test-run spends before it does any of the learner's work, and what
removes most of it.

## Why this is worth attacking

A java test-run starts two JVMs, not one. A start-point's `cyber-dojo.sh` runs
`javac`, and then `java -jar junit-platform-console-standalone-*.jar`. Both pay a
full JVM start, and both sit between a learner pressing [test] and a
traffic-light appearing. For java-junit the two together measure 634ms, which for
this start-point makes JVM startup not a component of the wait but most of it.

## What removes it

An AOT cache per JVM, recorded when the image is built and read at run time. A
cache holds the classes a JVM loads in the form the JVM wants them, so reading
one back costs a fraction of loading them again.

There are two caches because there are two JVMs, and a cache is validated
against the classpath of the JVM reading it. javac's classes are the compiler's;
the console's are JUnit's. One cache cannot satisfy both.

Measured against the kata java-junit ships, mean of five runs, JDK 26.0.2.1:

| run | mean |
| --- | --- |
| no caches, no flags | 634 ms |
| both caches, plus `-XX:TieredStopAtLevel=1` | 187 ms |

Those two are means of five, taken in the same container so that they can be
compared with each other. A second sample of the fast case, in its own
container, gave 220ms, so read it as roughly 190 to 220 and the saving as
roughly two thirds rather than as three significant figures.

No code changes, and the runner is not involved at all.

### Which flags carry the win

One-off per-span figures, taken on the earlier JDK 25 image:

| span | mean |
| --- | --- |
| javac | 277 ms |
| javac, TieredStopAtLevel + UseSerialGC | 247 ms |
| javac, AOTCache | 112 ms |
| junit console | 308 ms |
| junit console, TieredStopAtLevel=1 | 254 ms |
| junit console, UseSerialGC | 307 ms |
| junit console, both flags | 258 ms |
| junit console, AOTCache | 137 ms |
| junit console, AOTCache + TieredStopAtLevel=1 | 117 ms |

`-XX:TieredStopAtLevel=1` is the whole of the flags-only saving: on its own it
takes the console from 308ms to 254ms, where `-XX:+UseSerialGC` on its own
reaches 307ms, a difference too small to tell from noise. On top of a cache the
tiered flag is still worth having, taking the console from 137ms to 117ms.

`-XX:+UseSerialGC` earns its place for a different reason, and it is not
optional: without it, replaying a cache crashes the JVM. See the next section.
It costs nothing measurable, so there is no trade to weigh. Through the runner,
red measures 0.740s with it and 0.751s without, and green 0.550s against 0.506s.

Both flags trade steady-state throughput for startup speed, which is the right
trade only because the process lives for well under a second and is then thrown
away. That is a property of how the runner works, not of java.

## A cache needs the serial collector, or it crashes the JVM

Replaying a cache while the JVM chooses its own collector kills it:

```
#  SIGILL (0x4) at pc=0x0000ffff76c4cf38, pid=17, tid=18
# JVM: OpenJDK 64-Bit Server VM (26.0.2.1+1, mixed mode, client, sharing,
#      tiered, compressed oops, compressed class ptrs, g1 gc, linux-aarch64)
# Problematic frame:
# v  ~AdapterBlob 0x0000ffff76c4cf38
```

It is intermittent, which is what makes it dangerous: measured by running the
start-point's own `run_tests.sh` repeatedly, 3 of 5 runs failed with the cache
and the JVM's default collector, and 0 of 20 with `-XX:+UseSerialGC` added.
Twenty clean runs would be a 4% coincidence at even a 15% residual rate.

Two things about it are worth knowing before adopting a cache anywhere else.

**It does not reproduce under a plain `docker run`.** It needs the flags the
runner passes, and `source/server/runner.rb` in the runner repository is where
those live. Every direct container run of this image passes, which is why this
has to be measured through `run_tests.sh` rather than through a probe of one's
own. Reimplementing the invocation is how the crash gets missed.

**The amber light hides it.** A crash in javac still produces amber, which is the
colour the amber case expects, so amber passed in every failing run. Only red and
green exposed it. Checking a start-point on amber alone would show nothing wrong.

The runner's memory limit decides which collector the JVM picks when it is left
to choose, and so decides whether the crash appears at all: the published runner
allows 2GB, above the threshold at which the JVM picks G1. A tighter cap, such
as the 768MB the runner's pre-started-container-pool work prepares, is below that
threshold and would have the JVM pick the serial collector by itself. Naming the
flag means a start-point does not depend on which way that falls.

## A cache recorded at build time is read at run time

This is the claim the whole approach rests on, because recording happens in one
container and reading happens in another, so it is proved rather than assumed.

`-XX:AOTMode=on` refuses to start a JVM that cannot use the cache it was given,
rather than falling back to loading classes and running anyway. Both spans run
under it, in a fresh container started from the built image:

```
javac -J-XX:AOTCache=/aot/javac.aot -J-XX:AOTMode=on ...          exit 0
java  -XX:AOTCache=/aot/junit-console.aot -XX:AOTMode=on ...      runs the tests
```

Timings alone could not have shown this; a silently dropped cache looks like a
slow run, not a failure.

What this establishes is that a cache is read, and nothing more. It says nothing
about whether reading one is reliable, which is a separate question with a
separate answer, above. Both checks are needed.

## The caches survive a learner's edit

What decides whether the saving is a learner's figure or only a training run's.
Recorded against the kata as it arrives, then `Hiker.java` edited the way a
learner edits it, recompiled, and the same caches reused unrecorded. Per-span,
on the JDK 25 image:

| span | before the edit | after |
| --- | --- | --- |
| javac, AOTCache | 112 ms | 113 ms |
| junit console, AOTCache | 137 ms | 140 ms |
| junit console, AOTCache + Tiered | 117 ms | 118 ms |

Unchanged, and the reason is structural rather than lucky. The JVM's own
classpath is the console jar. A kata's classes reach JUnit through its
`--class-path` argument and JUnit's own classloader, so they are never what a
cache is validated against.

## What it costs in image size

| cache | bytes |
| --- | --- |
| `/aot/javac.aot` | 26,935,296 |
| `/aot/junit-console.aot` | 27,394,048 |

About 54MB per java LTF image. That is the whole price, and it is not nothing:
`faster-traffic-light.md` argues a node's page cache already cannot hold the
working set of 88 images, and this makes each java image larger.

## Where the pieces live

The JDK version belongs to this repository, and the caches do not.

- `docker/Dockerfile.base` here names the JDK exactly. 24 is the floor for
  recording a cache in one step with `-XX:AOTCacheOutput`; older JDKs need
  `-XX:AOTMode=record` and `-XX:AOTMode=create` as two steps. Every java LTF
  image inherits that JDK, which is what makes the approach available to all of
  them.
- A cache holds a test framework's classes, so it is recorded per LTF image
  rather than here. java-junit is the worked example:
  `docker/record_aot_caches.sh` and `docker/throwaway_kata` in
  `cyber-dojo-languages/java-junit`, and the flags in
  `cyber-dojo-start-points/java-junit/start_point/cyber-dojo.sh`. Those flags are
  `-XX:AOTCache=`, `-XX:+UseSerialGC` and `-XX:TieredStopAtLevel=1`, on both
  JVMs, with javac's spelled `-J...` so they reach the JVM rather than the
  compiler. The collector is not optional; see above.
- Each JVM gets its own cache. The two are recorded from the same command lines
  the start-point runs, so what they hold is what a kata loads.
- `docker/Dockerfile` here is generated and carries a DO NOT EDIT header. It is
  committed as an artefact and can name an older JDK than `Dockerfile.base`
  without affecting what is built, so read `Dockerfile.base` to learn the JDK.
- A new LTF image needs its `.dockerignore` to admit whatever the recording
  step copies in. java-junit's admitted only `jars/`, so the recording script
  was invisible to `COPY` until it was listed.

## Caveats

- Warm runs, aarch64 under Docker Desktop. Production is amd64 on a shared
  4-vCPU box. The per-span timings are single samples with no confidence
  intervals; the crash rates are 5 and 20 runs, which is enough to separate 3 in
  5 from 0 in 20 and not enough to put a bound on what remains.
- The crash was found on aarch64. Whether amd64 has it, and whether the serial
  collector is the whole of the answer there too, is untested.
- java-junit only. The other seven java start-points inherit the JDK but have no
  caches, and the other JVM families (kotlin, groovy, clojure, scala) are
  untested here. The flags should carry over; a cache has to be recorded per
  image.
- The per-span tables above were produced by a probe script that is not in any
  of these repositories, so those rows cannot currently be re-run. The
  whole-run figures can, as below.

## Open questions

- Whether the seven other java frameworks are each large enough to repay 54MB
  of image.
- What the crash actually is. The serial collector avoids it, which is enough to
  ship, but the cause is unexplained and so is the possibility that some other
  combination reaches it. A JDK bug report would need an amd64 answer first.
- Whether a residual rate survives the serial collector. 0 in 20 does not rule
  out a few percent, and a few percent of presses is not acceptable, so this is
  worth re-measuring whenever the JDK or the runner's limits move.
- Whether the approach reaches the other JVM families, and whether their bodies
  are large enough for it to matter. `faster-traffic-light.md` measures
  perl-testsimple's body at 12ms, where nothing like this would be worth doing.

## Measuring a change to any of this

Edit the start-point's own `cyber-dojo.sh` and run its own `run_tests.sh`, in a
loop. It reports each light and its duration, and it exercises the flags through
the runner, which is the only place the crash appears. Both the crash rate and
the durations quoted here came from it:

```
for i in $(seq 20); do
  ( cd <cyber-dojo-start-points>/java-junit && ./run_tests.sh ) > run_${i}.log 2>&1
  grep -E '^(red|amber|green)[[:space:]]' run_${i}.log
done
```

It handles uncommitted changes by copying the start-point aside and committing
there, so a candidate can be measured before anything is pushed.

A press can be timed on its own, without the runner, and that is where the 634ms
and the roughly 200ms come from:

```
docker run --rm --network none --user sandbox \
  --volume <cyber-dojo-start-points>/java-junit/start_point:/kata:ro \
  <image_name from the start-point's manifest.json> \
  bash -c '
    export CYBER_DOJO_SANDBOX=/tmp/kata
    mkdir -p ${CYBER_DOJO_SANDBOX}
    cp /kata/Hiker.java /kata/HikerTest.java ${CYBER_DOJO_SANDBOX}
    for i in 1 2 3 4 5; do
      rm -f ${CYBER_DOJO_SANDBOX}/*.class
      s=$(date +%s%3N); bash /kata/cyber-dojo.sh > /dev/null 2>&1; e=$(date +%s%3N)
      echo "$(( e - s )) ms"
    done'
```

The kata is copied out of its read-only mount because javac writes class files
beside the source. Delete the class files between runs, or the second run onwards
measures a compile that has nothing to do. For the no-cache figure, run the same
command with the `-XX:AOTCache=` and `-J-XX:AOTCache=` flags removed from
`cyber-dojo.sh`.

Timing a press this way cannot show the crash, and a green result here is not
evidence of correctness. Use `run_tests.sh` for that.
