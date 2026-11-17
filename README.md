<p align="center"><img src="assets/icon-128.png" width="96" alt="Ori Shader Warmer"></p>

# Ori Shader Warmer (Beta)

Ori and the Will of the Wisps stutters under CrossOver whenever something new appears on screen, because D3DMetal compiles each shader the first time it is used. This app compiles them all ahead of time, so the game runs smoothly from the first launch.

## Usage

1. Download the app from [Releases](../../releases/latest).
2. Open it and drop your Ori folder on the window, or click **Use Installed Game**.
3. Leave it for about 12 minutes, with the game closed.

You only need to do this once. If the stutter comes back after a macOS, CrossOver or game update, run it again.

## Requirements

- Apple Silicon Mac
- CrossOver, with D3DMetal enabled for the bottle
- The Steam version of the game

## Good to know

- macOS asks for permission to access data from other apps. The app needs it to read the game's files inside the CrossOver bottle.
- CrossOver games share one Metal shader cache, and this replaces it. Other games recompile their shaders the next time you play them.

## Building

Requires Xcode and mingw-w64.

```
brew install mingw-w64
./build.sh
```

`recipe/plan.txt.gz` is the list of shader states the app compiles. It was recorded from the game, across every scene and boss fight.

---

Not affiliated with Moon Studios or Xbox Game Studios.
