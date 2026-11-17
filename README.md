# FishLog

A small WoW: Forever addon that logs every fish (or other item) you catch
while fishing, along with where you caught it, so you can work out which
zones/spots are actually worth fishing -- the same kind of thing you did
with the original FishLog on Ascension.

## Install

Copy the whole `FishLog` folder into your WoW: Forever `Interface/AddOns/`
folder, so you end up with `Interface/AddOns/FishLog/FishLog.toc`. Then
enable it on the character-select AddOns list.

The `.toc` targets interface version `120105` (Forever's 12.1.5 API); if it
shows as "out of date", tick "Load out of date AddOns".

## What it logs, and how

Every time you successfully cast Fishing, FishLog remembers your current
zone and subzone. Whenever a loot message shows up in the next 30 seconds
(which covers the bobber wait, the bite, and reeling it in), it's counted as
a catch at that spot: item, quantity, zone/subzone, and whether it came from
a fishing pool or open water.

Catches are stored as running counts per (item, zone, subzone, pool-or-not)
combination, not as a raw event-by-event log -- so "I've caught 40 Firefin
Snapper in Ratchet" is one number that just keeps incrementing, rather than
40 separate log lines. That's what actually answers "is this spot worth
fishing", and it keeps the SavedVariables file small no matter how long you
fish.

### Pool vs. open water -- the honest limitation

Blizzard doesn't give addons a clean "you're fishing a pool right now" flag.
FishLog uses two real signals instead:

1. **Blizzard's own "fish from a pool" achievement tracking.** If catching
   from a pool ticks that achievement's progress right as your catch lands,
   that's a confirmed pool catch, not a guess. Whether this works at all
   depends on Forever's ruleset actually tracking that achievement -- if it
   doesn't, this signal just never fires and FishLog quietly falls back to
   the next one.
2. **Your mouseover tooltip at the moment you cast**, checked for text like
   "... School" -- since you usually click a pool directly, its tooltip is
   often still showing.

If neither signal catches it (you weren't hovering the pool, and/or the
achievement doesn't exist on this ruleset), the catch gets logged as open
water even if it was actually a pool. It should never mislabel a genuine
open-water catch as a pool, only possibly the other way around -- so treat
"open water" counts as an upper bound and "pool" counts as trustworthy when
they do show up.

### Other known limitations

- If you're partied with someone while fishing and their loot happens to
  print in your chat within that 30-second window, it could get miscounted
  as your own catch. Fine for solo fishing (the normal case for this kind
  of data), just worth knowing if you group up.
- Zone/subzone are whatever `GetRealZoneText()`/`GetSubZoneText()` report at
  the moment you cast -- if you're standing right on a zone boundary that
  could occasionally attribute a catch to the "wrong side," though this is
  rare in practice.

## Slash commands

- `/fishlog` or `/fishlog show` -- prints everything logged so far, grouped
  by zone/subzone, most-caught first.
- `/fishlog show <text>` -- same, filtered to zones/subzones containing that
  text (e.g. `/fishlog show barrens`).
- `/fishlog status` -- total catch count and how many distinct
  (item, zone, pool-type) combinations you've logged.
- `/fishlog export` -- opens a window with the whole log as a JSON blob
  (Ctrl+A, Ctrl+C to copy) -- meant to be pasted straight into a chat with
  Claude to figure out which spots are actually worth your time, the same
  way we've been using MarketScribe's export.
- `/fishlog reset confirm` -- wipes the log for this realm. `/fishlog reset`
  on its own just prints a warning rather than actually clearing anything.

## Casts per catch (v1.1)

`Casts.lua` follows every Fishing cast to its outcome, so failed casts count
too -- which is what you need for pools with a low catch chance, like Patch
of Elemental Water in Azshara's Bay of Storms:

- **caught** -- a loot line arrived for the cast
- **got away** -- "Your fish got away!": the skill roll failed
- **no bite** -- "No fish are hooked.": you clicked before the bite (a
  misclick, so it doesn't count against the catch chance)
- **abandoned** -- you moved/cancelled or let it time out; not counted as a cast

"Skill not high enough" refuses the cast outright, so it's never counted.

Each cast is added to the subzone it happened in, to the pool you were
hovering when you cast (same tooltip check as above; pool names now also
match "Patch", "Swarm", "Wreckage", "Debris", "Spill", "Waters" and
"Flotsam"), and to a manual session if one is running. Each bucket keeps
results per effective fishing skill (base + lure + buffs), so the
"(skill - zone minimum + 5)%" catch-chance formula can be checked.

- `/fishlog session start [label]` / `/fishlog session stop` -- count every
  cast between the two, with an on-screen line showing casts per catch and
  the rarest item so far. The most reliable way to time one pool.
- `/fishlog casts [text]` (or `/fishlog pools`) -- casts, catches, catch %,
  casts per item, and the per-skill breakdown for every bucket.
- `/fishlog hud` -- keep the on-screen line up outside sessions too.
- `/fishlog reset casts` -- clear only the cast stats.

`/fishlog export` now includes the cast stats too.

## Louder splash (v1.2)

Addons get no event when a fish bites, so FishLog can't pop up a "Catch!"
message -- but it can make the splash easier to hear. When you cast
Fishing, `Sound.lua` turns the Sound Effects slider to full and leaves
Master, Music, Ambience and Dialog exactly as you set them. 20 seconds after your last cast ends (or immediately if
something attacks you, or you log out) your own settings are put back.

Your original settings are saved to FishLogDB first, so if the game
crashes mid-fishing they're restored the next time you log in.

- `/fishlog loud` -- toggle it (on by default); `/fishlog loud on|off` to set it.

## Files

- `Core.lua` -- SavedVariables storage, the aggregated catch log, slash
  commands.
- `Tracker.lua` -- detects fishing catches (via chat loot messages, since
  most catches auto-loot with no loot window at all) and the pool/open
  water heuristic.
- `Casts.lua` -- follows each cast to its outcome for casts-per-catch stats,
  the session HUD and `/fishlog casts`.
- `Sound.lua` -- the louder-splash sound mix while fishing.
- `Export.lua` -- builds the `/fishlog export` JSON blob and its copy
  window.
