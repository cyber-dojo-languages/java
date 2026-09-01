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
reaches 307ms, a difference too small to tell from noise. So `UseSerialGC` is
not adopted. On top of a cache the tiered flag is still worth having, taking the
console from 137ms to 117ms.

Both flags trade steady-state throughput for startup speed, which is the right
trade only because the process lives for well under a second and is then thrown
away. That is a property of how the runner works, not of java.

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
  `cyber-dojo-languages/java-junit`, and the `-XX:AOTCache=` flags in
  `cyber-dojo-start-points/java-junit/start_point/cyber-dojo.sh`.
- `docker/Dockerfile` here is generated and carries a DO NOT EDIT header. It is
  committed as an artefact and can name an older JDK than `Dockerfile.base`
  without affecting what is built, so read `Dockerfile.base` to learn the JDK.
- A new LTF image needs its `.dockerignore` to admit whatever the recording
  step copies in. java-junit's admitted only `jars/`, so the recording script
  was invisible to `COPY` until it was listed.

## Caveats

- Warm runs, aarch64 under Docker Desktop, no repeats and so no confidence
  intervals. Production is amd64 on a shared 4-vCPU box.
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
- Whether the approach reaches the other JVM families, and whether their bodies
  are large enough for it to matter. `faster-traffic-light.md` measures
  perl-testsimple's body at 12ms, where nothing like this would be worth doing.

## Reproducing the whole-run figures

Needs only this repository's image chain and the start-point.

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
beside the source. Delete the class files between runs, or the second run
onwards measures a compile that has nothing to do. For the no-cache figure, run
the same command with the `-XX:AOTCache=` and `-J-XX:AOTCache=` flags removed
from `cyber-dojo.sh`.
