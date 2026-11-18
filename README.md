<p align="center"><img src="assets/icon-128.png" width="96" alt="Ori Shader Warmer"></p>

# Ori Shader Warmer (Beta)

Ori and the Will of the Wisps stutters under CrossOver and NotProton whenever something new appears on screen, because D3DMetal compiles each shader the first time it is used. This app compiles them all ahead of time, so the game runs smoothly from the first launch.

## Usage

1. Download the app from [Releases](../../releases/latest).
2. Open it and click **Find Game**, or drop the game folder on the window.
3. Leave it running with the game closed. It takes 10 to 30 minutes depending on your Mac.

You only need to do this once. If the stutter comes back after a macOS, CrossOver, NotProton or game update, run it again.

## Requirements

- Apple Silicon Mac
- CrossOver with D3DMetal, or NotProton with the Rosetta runner and D3DMetal
- The Steam version of the game

## Good to know

- If you have more than one CrossOver or NotProton setup, the app may ask which one you play with. Shaders only help the exact CrossOver build and D3DMetal version they were built for.
- NotProton users: launch Ori with NotProton once before running the app, so its setup for the game exists.
- macOS asks for permission to access data from other apps, and to access an external drive if the game is on one. The app needs both to read the game's files.
- CrossOver and NotProton games share one Metal shader cache, and this replaces it. Other games recompile their shaders the next time you play them.

## Why Ori needs this

Ori is a DirectX 11 game, and DirectX 11 doesn't tell the graphics driver in advance which shader and render-state combinations a game will use. D3DMetal only finds out when something is drawn, and then has to build a Metal pipeline for that exact combination on the spot, which is the hitch. Ori ships about 20,000 shaders, and its effects combine them with many different blend, depth and vertex settings, so the number of combinations is far larger than the shader count. The game's own loading doesn't prepare these combinations ahead of time.

The app works from a list of about 90,000 combinations recorded from the game itself, across every scene and boss fight, and builds them ahead of time. The result is specific to the CrossOver build and D3DMetal version that made it, which is why it has to run on your own Mac and why it asks which setup you play with.

## Building

Requires Xcode and mingw-w64.

```
brew install mingw-w64
./build.sh
```

`recipe/plan.txt.gz` is the list of combinations the app compiles.

---

Not affiliated with Moon Studios or Xbox Game Studios.
