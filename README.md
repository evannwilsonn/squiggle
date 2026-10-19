# Squiggle

A live drawing game where people race a neural network. One player draws a word; everyone else types guesses, and so does a network trained on Google's Quick, Draw! doodles, which calls out its guesses as the drawing takes shape. Play with up to eight friends in a room, or alone against the machine. It's written in Elixir: the network is trained with Nx and Axon, and the game runs on Phoenix LiveView, with every room its own process.

[![pipeline](https://github.com/evannwilsonn/squiggle/actions/workflows/pipeline.yml/badge.svg)](https://github.com/evannwilsonn/squiggle/actions/workflows/pipeline.yml)

**Live demo:** on Google Cloud Run, deployed from `main` by the pipeline (see [Deployment](#7-deployment)).

Project 13c of my AI project roadmap, the capstone, built three times in a language I hadn't used before. The other two are [Lure](https://github.com/evannwilsonn/lure) and [Recall](https://github.com/evannwilsonn/recall).

## 1. Problem

Recognise a doodle while it's being drawn, fast enough to play against, and make that the core of a multiplayer game that runs on one small server. Success is how often the network's first guess (and its top three) is right on doodles it never saw, and whether a guess comes back while the drawer is still drawing.

## 2. Data

[Quick, Draw!](https://github.com/googlecreativelab/quickdraw-dataset) (Google, CC BY 4.0) has millions of doodles people drew in under 20 seconds, each available as a 28 × 28 grayscale bitmap, centred and scaled to fill the frame.

- 24 categories that are quick to draw and look different from each other: airplane, apple, banana, bicycle, car, cat, clock, cloud, envelope, eye, fish, flower, guitar, house, key, ladder, moon, pizza, rainbow, snowman, star, sun, tree, umbrella.
- The first 7,000 doodles of each, fetched with HTTP range requests rather than downloading the full files: 5,000 to train on, 1,000 to choose the epoch, 1,000 to test. That's 120,000 / 24,000 / 24,000.

## 3. Baseline

- **Chance:** 1 in 24, 4.2%.
- **Nearest average doodle:** average every training doodle of each category into one picture, then call each test doodle whichever average it's closest to. Written from scratch in Nx. 58.0% on test.

## 4. Model

```
28×28 doodle ─► 3×3 conv 32 ─► 3×3 conv 32 ─► max pool ─► 3×3 conv 64 ─► 3×3 conv 64 ─► max pool
              (batch norm + ReLU after each conv)
            ─► 256 units, dropout 0.4 ─► 24-way softmax
```

- About 0.9 million weights, built and trained with Axon (Adam, learning rate 1e-3, batches of 128, a fresh shuffle each epoch), compiled with EXLA on the CPU. The epoch with the best validation accuracy ships.
- **Serving:** the network sits behind `Nx.Serving`, so drawings from every player in every room queue for a few milliseconds and run as one batch.
- **Matching the training data:** the drawer's browser keeps every stroke and, twice a second while the drawing changes, renders a copy the way Quick, Draw! bitmaps were made. It crops to the ink, scales the longer side to fill the frame with a small margin, centres the drawing, draws thick white lines on black, and shrinks it to 28 × 28 in steps. Only those 784 bytes go to the server.
- **The game:** each room is a GenServer under a `DynamicSupervisor`, found through a `Registry` by its four-letter code. Strokes go from the drawer to the room and out to every player over PubSub. The machine's top guess is posted to the chat when it changes; it "gets it" once its top guess is the word with at least 40% confidence. Guessers race it: up to 150 points the sooner you get it, and 50 to the drawer for each person (and the machine) who does. A refresh keeps your score; an empty room shuts down after two minutes.

## 5. Evaluation

On the 24,000 test doodles:

| Model | First guess | Top three |
|---|---|---|
| Chance | 4.2% | 12.5% |
| Nearest average doodle | 58.0% | |
| **Convolutional network (shipped)** | **91.8%** | **96.6%** |

Validation accuracy by epoch was 89.3%, 91.2% and 91.9%; training stopped at three epochs because each takes about eight minutes on two CPU cores and the curve had flattened. The hardest categories are moon (81%), banana (84%), cat (85%) and key (85%). The most common mix-ups are banana read as moon (124 times), moon read as banana (53), moon read as pizza (47) and star read as airplane (43), which are mostly curves and crescents that look alike at 28 × 28.

In the game, a guess comes back in well under a second: the browser sends a new picture about every half second while the drawer draws, and the network takes milliseconds.

## 6. Improvement

- **Look timing.** The first build never asked the machine: it rate-limited "looks" by comparing the BEAM's monotonic clock with 0, and that clock can be negative. "Never looked" is now `nil`, and a LiveView test sends a ring-shaped doodle and checks the guesses appear.
- **Fewer epochs.** The first run was set to eight epochs (over an hour). Epoch one already reached 89% on validation, so it was cut to three, which gained 2.6 points for about 15 more minutes, with each epoch adding less than the one before.
- **Partial downloads.** Reading only the bytes for the first 7,000 doodles of each category keeps the training data at about 130 MB instead of several GB.

## 7. Deployment

```
push to main ─► check: format, compile --warnings-as-errors, mix test
              └► image: docker build ─► smoke test on :7860 (page + framing header) ─► ghcr.io/evannwilsonn/squiggle
                                                                                         └► Google Cloud Run
```

- **Container:** a Phoenix release on Debian slim, uid 1000, port 7860, with the trained weights (`priv/model/net.nx`, 3.5 MB) inside. Rooms live in memory, so one instance holds every game.
- **Cloud Run:** the pipeline's last job copies this commit's tested image from GHCR to Google's registry and deploys it to Cloud Run in us-east1, with 1 GB of memory and exactly one instance, so every room lives on the same server. It scales to zero when nobody's using it. It logs in to Google through workload identity, so no key is stored anywhere; the one-time setup is `cloudrun-setup.sh` in [Conveyor](https://github.com/evannwilsonn/conveyor), and the job runs once the repo has the variables it prints. Hugging Face Spaces was the first plan, but Docker Spaces now need a paid account.
- **Pipeline board:** the run shows up on [Conveyor](https://evannwilsonn.github.io/conveyor/).

## Reproducing the numbers

```sh
mix deps.get
mix squiggle.train --epochs 3   # fetches the doodles, trains, writes priv/model/ and results/eval.json
mix test
mix phx.server                  # http://localhost:4000
```

## Layout

```
lib/squiggle/            sketches (data), net, guesser (serving), room (the game)
lib/mix/tasks/           squiggle.train
lib/squiggle_web/live/   home_live.ex, room_live.ex
assets/js/hooks.js       the drawing pad, the Quick, Draw!-style rasteriser, the clock
priv/model/              net.nx, eval.json
```

## Limits

- The machine only knows 24 things, so the drawer is always given one of them.
- It was trained on how people draw in 20 seconds with a mouse or finger. Careful, detailed drawings can confuse it more than scribbles do.
- Rooms are in memory on one server: a restart ends every game.
