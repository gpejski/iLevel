# iLevel - World of Warcraft Addon

**iLevel** is a lightweight, high-performance World of Warcraft (Retail / Patch 12.1.5 & The War Within) addon that dynamically calculates and displays a character's equipped item level directly on their tooltip.

---

## ✨ Features

- **Dynamic iLevel Calculation**: Calculates the true equipped item level for any player character you mouseover or target.
- **Accurate Retail Formula**:
  - Evaluates all 16 equipment slots.
  - Correctly weights Two-Handed weapons (counts twice when off-hand is empty, matching Blizzard's average item level algorithm).
  - Instantaneous native API integration (`GetAverageItemLevel`) when inspecting yourself.
- **Smooth Rarity & Tier Color Gradient**:
  - Dynamically color-codes the item level number based on *The War Within* gear progression brackets:
    - **Explorer** (Green): `554+`
    - **Adventurer** (Blue): `580+`
    - **Veteran** (Purple): `593+`
    - **Champion** (Rich Purple): `606+`
    - **Hero** (Magenta): `619+`
    - **Mythic** (Orange): `639+`
    - **Artifact** (Gold): `650+`
  - Interpolates colors smoothly between tier thresholds for a polished, modern look.
- **Throttled & Non-Intrusive Inspect Engine**:
  - Queues and paces background inspection requests (`0.6s` cooldown) to prevent server throttling or disconnects.
  - Automatically yields to Blizzard's native Inspect window (`InspectFrame`) so it never cancels or interferes with manual player inspection.
  - Includes a watchdog timer (`2.5s`) to safely recover if the server drops an inspect packet.
- **Smart Asynchronous Caching**:
  - Caches inspected player item levels by GUID for 15 minutes to eliminate redundant network queries.
  - Automatically retries if the client is still downloading item metadata from the Blizzard server.

---

## 📁 File Structure

```text
iLevel/
├── iLevel.toc       # Addon manifest and interface version metadata
├── iLevel.lua       # Addon logic, inspect engine, calculator, and tooltip hooks
├── icon.svg         # Scalable vector master icon
├── icon.png         # CurseForge project avatar (PNG)
├── icon.jpg         # CurseForge project avatar (JPG)
└── README.md        # Documentation and installation guide
```

---

## 🚀 Installation

1. Locate your World of Warcraft installation directory:
   - **Windows**: `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\`
   - **macOS**: `/Applications/World of Warcraft/_retail_/Interface/AddOns/`
2. Copy or symlink this folder (`iLevel`) into the `AddOns` directory:
   ```bash
   # Example for macOS symlink:
   ln -s "/Users/garrypejski/Code/iLevel" "/Applications/World of Warcraft/_retail_/Interface/AddOns/iLevel"
   ```
3. Ensure the folder is named **`iLevel`** (matching the `.toc` filename `iLevel.toc`).
4. Launch World of Warcraft (or type `/reload` in-game if the game is already running).
5. Hover over yourself or any player in the world or in unit frames!

---

## ⌨️ Slash Commands

Use `/ilvl` or `/ilevel` in the in-game chat:

| Command | Description |
| :--- | :--- |
| `/ilvl` | Displays your current equipped item level, addon status, and total cached characters. |
| `/ilvl clear` | Flushes the inspected character cache. |
| `/ilvl help` | Displays the help menu and command list. |

---

## 🛠️ Customization

You can easily adjust the settings inside [iLevel.lua](file:///Users/garrypejski/Code/iLevel/iLevel.lua):

- **Cache Lifetime**: Adjust `defaults.cacheTTL` (default is `900` seconds / 15 minutes).
- **Color Brackets**: Customize the `COLOR_TIERS` table to update ilvl thresholds for future raid tiers or seasons.
