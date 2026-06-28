# BasePaint — ERC-1155 Collaborative Art Contract

> **Network:** Base Mainnet  
> **Address:** [`0xBa5e05cb26b78eDa3A2f8e3b3814726305dcAc83`](https://basescan.org/address/0xBa5e05cb26b78eDa3A2f8e3b3814726305dcAc83)  
> **Compiler:** Solidity `^0.8.13` (verified with `v0.8.15`, 200 optimizer runs, london EVM)  
> **License:** UNLICENSED

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Dependencies](#dependencies)
- [State Variables](#state-variables)
  - [Canvas Struct](#canvas-struct)
- [Events](#events)
- [Constructor](#constructor)
- [Admin / Owner Functions](#admin--owner-functions)
- [Core Functions](#core-functions)
  - [paint()](#paint)
  - [mint()](#mint)
  - [authorWithdraw()](#authorwithdraw)
- [View Functions](#view-functions)
- [Economic Flow](#economic-flow)
- [Access Control Summary](#access-control-summary)
- [Known Limitations / Design Notes](#known-limitations--design-notes)
- [Local Development](#local-development)

---

## Overview

BasePaint is an **on-chain collaborative pixel art protocol**. Every `epochDuration` seconds a new "day" begins and a fresh canvas opens. Artists who hold a **Brush NFT** can call `paint()` to submit pixel data to the current day's canvas. When the day closes, anyone can mint an ERC-1155 open-edition NFT commemorating that day's artwork by paying `openEditionPrice` ETH per token. The ETH raised is split between the **owner** (a fixed fee) and all **artists** proportional to how many pixels they contributed.

```
┌─────────────┐   holds    ┌──────────────┐
│  Artist     │──────────▶│  Brush NFT   │  (IBasePaintBrush — ERC-721)
└─────────────┘            └──────────────┘
       │ paint()
       ▼
┌─────────────────────────────────────────┐
│            BasePaint.sol                │  ◀── ERC-1155 token contract
│                                         │
│  Day N canvas (open for epochDuration)  │
│  ┌────────────────────────────────────┐ │
│  │ contributions[address] → pixels    │ │
│  │ brushUsed[tokenId]    → pixels     │ │
│  │ totalContributions                 │ │
│  │ totalRaised (ETH, after owner cut) │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
       │ mint()                   │ authorWithdraw()
       ▼                          ▼
  Collector gets            Artist claims pro-rata
  ERC-1155 NFT              share of totalRaised
```

---

## Architecture

| Layer | Contract | Role |
|---|---|---|
| Access pass | `IBasePaintBrush` (ERC-721) | Gate-keeps who can call `paint()` |
| Core | `BasePaint` (ERC-1155) | Canvas, minting, payments |
| Ownership | OpenZeppelin `Ownable` | Admin controls |

The contract inherits:
- **`ERC1155`** from OpenZeppelin — provides multi-token balances, transfers, batch operations.
- **`Ownable`** from OpenZeppelin — provides `onlyOwner` modifier and ownership transfer.

---

## Dependencies

```
openzeppelin-contracts/
  contracts/token/ERC1155/ERC1155.sol   ← multi-token standard
  contracts/access/Ownable.sol          ← ownership helpers
src/
  BasePaintBrush.sol                    ← IBasePaintBrush interface
  BasePaint.sol                         ← main contract
```

---

## State Variables

### `brushes` — `IBasePaintBrush`

```solidity
IBasePaintBrush public brushes;
```

Reference to the Brush NFT contract. Used inside `paint()` to verify that `msg.sender` owns the Brush token they're claiming to paint with. Set once in the constructor and never changed.

---

### `epochDuration` — `uint256` (immutable)

```solidity
uint256 public immutable epochDuration;
```

The length of each painting "day" in seconds. Stored as an `immutable` — baked into the bytecode at deployment, cannot be updated. Divides the wall-clock time since `startedAt` to determine the current day index.

Example: if `epochDuration = 86400` (24 hours), then `today()` increments by 1 every 24 hours.

---

### `canvases` — `mapping(uint256 => Canvas)`

```solidity
mapping(uint256 => Canvas) public canvases;
```

Maps each day index to its `Canvas` struct. Day `0` is the very first epoch, day `1` the second, and so on. The `public` visibility generates a getter for `totalContributions` and `totalRaised` (the non-mapping fields), but the nested mappings (`contributions`, `brushUsed`) must be read via their dedicated view functions.

---

### Canvas Struct

```solidity
struct Canvas {
    uint256 totalContributions;
    uint256 totalRaised;
    mapping(address => uint256) contributions;
    mapping(uint256 => uint256) brushUsed;
}
```

| Field | Type | Description |
|---|---|---|
| `totalContributions` | `uint256` | Sum of all pixel-contributions from all artists on this day. Used as the denominator when calculating an artist's payout share. |
| `totalRaised` | `uint256` | ETH (wei) accumulated from `mint()` calls for this day, **after** the owner's fee has been subtracted. This is what artists share between them. |
| `contributions[address]` | `mapping` | How many pixels each specific address contributed on this day. Zeroed out when that artist calls `authorWithdraw()`. |
| `brushUsed[tokenId]` | `mapping` | How many pixels a specific Brush token ID has painted on this day. Purely informational / for off-chain use. |

---

### `startedAt` — `uint256`

```solidity
uint256 public startedAt;
```

UNIX timestamp (seconds) set when the owner calls `start()`. Remains `0` until then, which causes `today()`, `paint()`, and `mint()` to revert. Acts as the protocol's genesis point.

---

### `openEditionPrice` — `uint256`

```solidity
uint256 public openEditionPrice = 0.0026 ether;
```

Price in wei to mint a single open-edition NFT for any completed day. Defaults to 0.0026 ETH. The owner can change this at any time via `setOpenEditionPrice()`.

---

### `ownerFeePartsPerMillion` — `uint256`

```solidity
uint256 public ownerFeePartsPerMillion = 100_000;
```

The owner's cut of each mint, expressed in parts-per-million. Default `100_000` = 10% (100,000 / 1,000,000). For example, if a mint generates 1 ETH total, `0.1 ETH` goes to `ownerEarned` and `0.9 ETH` goes to `canvases[day].totalRaised` for artists to claim.

---

### `ownerEarned` — `uint256`

```solidity
uint256 public ownerEarned;
```

Running total of ETH (wei) accumulated for the owner from mint fees, but not yet withdrawn. Reset to `0` when `ownerWithdraw()` is called.

---

## Events

### `Started(uint256 timestamp)`

Emitted once when `start()` is called. `timestamp` is the value stored in `startedAt`.

---

### `Painted(uint256 indexed day, uint256 tokenId, address author, bytes pixels)`

Emitted on every successful `paint()` call.

| Param | Description |
|---|---|
| `day` | The current day index (indexed for efficient filtering). |
| `tokenId` | The Brush NFT used to authorise this paint action. |
| `author` | The address that called `paint()`. |
| `pixels` | The raw pixel payload submitted. Off-chain renderers decode this to produce the visual canvas. |

---

### `ArtistsEarned(uint256 indexed day, uint256 amount)`

Emitted during `mint()` for each day being minted. `amount` is the artist-share (total cost minus owner fee) added to `canvases[day].totalRaised`.

---

### `ArtistWithdraw(uint256 indexed day, address author, uint256 amount)`

Emitted when an artist successfully calls `authorWithdraw()`. Records which day they withdrew from, who withdrew, and how much ETH was transferred.

---

### `Minted(uint256 indexed day, address minter, uint256 amount)`

Emitted once per day entry inside `mint()`. Records which day's NFTs were minted, by whom, and how many.

---

### `OwnerWithdraw(uint256 amount)`

Emitted when the owner calls `ownerWithdraw()`. `amount` is the total ETH transferred.

---

## Constructor

```solidity
constructor(IBasePaintBrush _brushes, uint256 _epochDuration)
```

| Param | Description |
|---|---|
| `_brushes` | Address of the deployed `IBasePaintBrush` (Brush NFT) contract. |
| `_epochDuration` | How long each painting epoch lasts, in seconds. |

Sets `brushes` and `epochDuration`. Does **not** start the protocol — the owner must call `start()` separately.

---

## Admin / Owner Functions

### `start()`

```solidity
function start() public onlyOwner
```

Starts the protocol by recording `block.timestamp` into `startedAt`. Can only be called once (reverts if `startedAt != 0`). After this call, `today()` returns `0` and artists can begin painting.

---

### `setOpenEditionPrice(uint256 price)`

```solidity
function setOpenEditionPrice(uint256 price) public onlyOwner
```

Updates the per-token mint price. Takes effect immediately for all future `mint()` calls. Does not retroactively affect ongoing or past days.

| Param | Description |
|---|---|
| `price` | New price in wei (e.g. `0.005 ether`). |

---

### `setOwnerFee(uint256 fee)`

```solidity
function setOwnerFee(uint256 fee) public onlyOwner
```

Updates the owner's fee in parts-per-million. Reverts if `fee > 1_000_000` (which would be > 100%). Setting it to `0` gives 100% of proceeds to artists.

| Param | Description |
|---|---|
| `fee` | Fee in ppm. `100_000` = 10%, `500_000` = 50%, `1_000_000` = 100%. |

---

### `ownerWithdraw()`

```solidity
function ownerWithdraw() public onlyOwner
```

Transfers the entire `ownerEarned` balance to the owner address and resets it to zero. Uses `payable(owner()).transfer()`.

---

## Core Functions

### `paint()`

```solidity
function paint(uint256 tokenId, bytes calldata pixels) public
```

The central creative action. Allows a Brush NFT holder to submit pixel data to the current day's canvas.

**Checks:**
1. Protocol must have started (`startedAt != 0`).
2. `msg.sender` must own the Brush token with ID `tokenId` (checked via `brushes.ownerOf(tokenId)`).

**Effects:**
- Calculates `pixelCount = pixels.length / 3` — each pixel is encoded as 3 bytes (x-coordinate, y-coordinate, color index).
- Increments `canvas.totalContributions` by `pixelCount`.
- Increments `canvas.contributions[msg.sender]` by `pixelCount`.
- Increments `canvas.brushUsed[tokenId]` by `pixelCount`.
- Emits `Painted`.

> **Note:** The pixel data itself is not stored on-chain beyond the event log. Off-chain indexers listen for `Painted` events and reconstruct the canvas visually.

| Param | Description |
|---|---|
| `tokenId` | The Brush NFT ID being used to paint. |
| `pixels` | Raw encoded pixel data. Each 3 bytes = one pixel (x, y, colorIndex). |

---

### `mint()`

```solidity
function mint(uint256[] calldata days, uint256[] calldata amounts) public payable
```

Allows anyone to mint open-edition ERC-1155 NFTs for one or more **completed** days by paying ETH.

**Checks:**
1. Protocol must have started.
2. `days.length == amounts.length`.
3. Each `day` must be strictly less than `today()` (i.e. the day must be finished).
4. Each `amounts[i] > 0`.
5. `msg.value` must equal the exact total cost (`openEditionPrice × sum(amounts)`).

**Effects per day:**
- Calculates `cost = openEditionPrice * amounts[i]`.
- Splits cost: `ownerCut = cost * ownerFeePartsPerMillion / 1_000_000`.
- Adds `ownerCut` to `ownerEarned`.
- Adds `cost - ownerCut` to `canvases[day].totalRaised`.
- Calls `_mint(msg.sender, day, amounts[i], "")` — issues ERC-1155 tokens with `id = day`.
- Emits `Minted` and `ArtistsEarned`.

> The ERC-1155 token ID for each day equals the day index. Day 0 → token ID 0, Day 1 → token ID 1, etc.

| Param | Description |
|---|---|
| `days` | Array of day indices to mint from. |
| `amounts` | Number of tokens to mint for each corresponding day. |

---

### `authorWithdraw()`

```solidity
function authorWithdraw(uint256 day) public
```

Allows an artist to claim their proportional share of the ETH raised from minting a specific completed day.

**Checks:**
1. `day < today()` — the day must be complete.
2. `canvas.contributions[msg.sender] > 0` — caller must have painted on that day.
3. Computed `amount > 0`.

**Payout formula:**

```
amount = totalRaised[day] × contributions[msg.sender] / totalContributions[day]
```

**Effects:**
- Zeroes out `canvas.contributions[msg.sender]` **before** the transfer (re-entrancy guard).
- Transfers `amount` wei to `msg.sender`.
- Emits `ArtistWithdraw`.

> **Important:** Each artist can only withdraw once per day. Their contribution record is deleted after withdrawal, so repeat calls revert with "No contributions".

| Param | Description |
|---|---|
| `day` | The completed day index to claim earnings from. |

---

## View Functions

### `today()`

```solidity
function today() public view returns (uint256)
```

Returns the current epoch / day index. Reverts if the protocol hasn't started yet.

```
today() = (block.timestamp - startedAt) / epochDuration
```

---

### `contributions(uint256 day, address author)`

```solidity
function contributions(uint256 day, address author) public view returns (uint256)
```

Returns how many pixels `author` contributed on `day`. Returns `0` if they didn't paint or have already withdrawn.

---

### `brushUsed(uint256 day, uint256 tokenId)`

```solidity
function brushUsed(uint256 day, uint256 tokenId) public view returns (uint256)
```

Returns how many pixels Brush token `tokenId` painted on `day`. Useful for off-chain leaderboards or analytics.

---

### `uri(uint256 id)`

```solidity
function uri(uint256 id) public pure override returns (string memory)
```

Overrides the ERC-1155 base URI to return a fully-qualified metadata URL per token:

```
https://basepaint.xyz/api/art/{id}
```

where `{id}` is the day number. The BasePaint backend serves JSON metadata and the rendered artwork image at this endpoint.

---

## Economic Flow

```
Collector calls mint(day, amount)
  │
  ├─ Pays: openEditionPrice × amount ETH
  │
  ├─ Owner cut = total × (ownerFeePartsPerMillion / 1_000_000)
  │   └─ Accumulates in ownerEarned
  │        └─ Withdrawn by owner via ownerWithdraw()
  │
  └─ Artist pool = total - ownerCut
      └─ Stored in canvases[day].totalRaised
           └─ Each artist claims:
              totalRaised × (myContributions / totalContributions)
              via authorWithdraw(day)
```

**Example (default settings, 100 pixels by Alice, 400 by Bob, 1 ETH raised):**

| Recipient | Calculation | Amount |
|---|---|---|
| Owner (10%) | `1 ETH × 100_000 / 1_000_000` | 0.1 ETH |
| Artist pool | `1 ETH - 0.1 ETH` | 0.9 ETH |
| Alice (20%) | `0.9 ETH × 100 / 500` | 0.18 ETH |
| Bob (80%) | `0.9 ETH × 400 / 500` | 0.72 ETH |

---

## Access Control Summary

| Function | Who Can Call |
|---|---|
| `start()` | Owner only |
| `setOpenEditionPrice()` | Owner only |
| `setOwnerFee()` | Owner only |
| `ownerWithdraw()` | Owner only |
| `paint()` | Any Brush NFT holder |
| `mint()` | Anyone (payable) |
| `authorWithdraw()` | Any artist who painted on that day |
| `today()` | Anyone (view) |
| `contributions()` | Anyone (view) |
| `brushUsed()` | Anyone (view) |
| `uri()` | Anyone (pure view) |

---

## Known Limitations / Design Notes

1. **No partial withdrawal** — `authorWithdraw()` pays out the full entitlement in one call. Artists can't split withdrawals across multiple transactions.

2. **Contribution tracking deleted on withdrawal** — once an artist withdraws, `contributions[msg.sender]` is zeroed. This is intentional (re-entrancy protection) but means the on-chain record of who painted is lost after payout.

3. **`brushUsed` is not zeroed** — unlike `contributions`, the `brushUsed` mapping persists permanently for analytics purposes.

4. **Pixel data is off-chain** — the `pixels` bytes are emitted as an event but not stored in contract state, keeping gas costs low. The canvas is reconstructed by off-chain indexers.

5. **Integer division truncation** — the payout formula `totalRaised × contributions / totalContributions` can lose up to 1 wei per artist due to integer division. Dust remains in the contract.

6. **No per-day price locking** — `openEditionPrice` can change between epochs. The price in effect at the time `mint()` is called applies, regardless of when the day ended.

---

## Local Development

### Prerequisites

- [Foundry](https://getfoundry.sh/) (`forge`, `cast`)

### Setup

```bash
git clone https://github.com/kingmariano/BasePaint.git
cd BasePaint
forge install OpenZeppelin/openzeppelin-contracts
```

### Build

```bash
forge build
```

### Test (fork)

```bash
# Fork Base mainnet to interact with the live contract
forge test --fork-url $BASE_RPC_URL -vvv
```

### Cast — read current day

```bash
cast call 0xBa5e05cb26b78eDa3A2f8e3b3814726305dcAc83 \
  "today()(uint256)" \
  --rpc-url $BASE_RPC_URL
```

### Cast — check an artist's contributions

```bash
cast call 0xBa5e05cb26b78eDa3A2f8e3b3814726305dcAc83 \
  "contributions(uint256,address)(uint256)" \
  <DAY_INDEX> <ARTIST_ADDRESS> \
  --rpc-url $BASE_RPC_URL
```

---

*Documentation generated from verified source code at [BaseScan](https://basescan.org/address/0xBa5e05cb26b78eDa3A2f8e3b3814726305dcAc83#code).*
