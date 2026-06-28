// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IBasePaintBrush} from "./BasePaintBrush.sol";

contract BasePaint is ERC1155("https://basepaint.xyz/api/art/{id}"), Ownable {
    // ─────────────────────────────────────────────────────────────────────
    //  External contract references
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The Brush NFT contract — only Brush holders can paint.
    IBasePaintBrush public brushes;

    // ─────────────────────────────────────────────────────────────────────
    //  Immutables & constants
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Fixed duration (in seconds) of each painting epoch / "day".
    uint256 public immutable epochDuration;

    // ─────────────────────────────────────────────────────────────────────
    //  Canvas storage
    // ─────────────────────────────────────────────────────────────────────

    struct Canvas {
        /// @notice Total pixel-contributions recorded across all artists for this day.
        uint256 totalContributions;
        /// @notice Total ETH (in wei) raised from open-edition mints for this day.
        uint256 totalRaised;
        /// @notice How many contributions each address made on this day.
        mapping(address => uint256) contributions;
        /// @notice How many pixels each Brush token ID has painted on this day.
        mapping(uint256 => uint256) brushUsed;
    }

    /// @notice day index => Canvas data.
    mapping(uint256 => Canvas) public canvases;

    // ─────────────────────────────────────────────────────────────────────
    //  Protocol state
    // ─────────────────────────────────────────────────────────────────────

    /// @notice UNIX timestamp at which the first epoch started.
    uint256 public startedAt;

    /// @notice Price (in wei) to mint one open-edition NFT for a completed day.
    uint256 public openEditionPrice = 0.0026 ether;

    /// @notice Owner's fee expressed in parts-per-million (100_000 = 10%).
    uint256 public ownerFeePartsPerMillion = 100_000;

    /// @notice Accumulated ETH earned by the owner (fees not yet withdrawn).
    uint256 public ownerEarned;

    // ─────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────

    event Started(uint256 timestamp);
    event Painted(uint256 indexed day, uint256 tokenId, address author, bytes pixels);
    event ArtistsEarned(uint256 indexed day, uint256 amount);
    event ArtistWithdraw(uint256 indexed day, address author, uint256 amount);
    event Minted(uint256 indexed day, address minter, uint256 amount);
    event OwnerWithdraw(uint256 amount);

    // ─────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────

    /// @param _brushes   Address of the IBasePaintBrush (Brush NFT) contract.
    /// @param _epochDuration  Length of each painting period in seconds.
    constructor(IBasePaintBrush _brushes, uint256 _epochDuration) {
        brushes = _brushes;
        epochDuration = _epochDuration;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Admin / owner functions
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Kick off the very first epoch. Can only be called once by the owner.
    function start() public onlyOwner {
        require(startedAt == 0, "Already started");
        startedAt = block.timestamp;
        emit Started(startedAt);
    }

    /// @notice Update the open-edition mint price.
    /// @param price New price in wei.
    function setOpenEditionPrice(uint256 price) public onlyOwner {
        openEditionPrice = price;
    }

    /// @notice Update the owner fee. Max 100% (1_000_000 ppm).
    /// @param fee New fee in parts-per-million.
    function setOwnerFee(uint256 fee) public onlyOwner {
        require(fee <= 1_000_000, "Fee too high");
        ownerFeePartsPerMillion = fee;
    }

    /// @notice Withdraw accumulated owner fees.
    function ownerWithdraw() public onlyOwner {
        uint256 amount = ownerEarned;
        ownerEarned = 0;
        payable(owner()).transfer(amount);
        emit OwnerWithdraw(amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Core: painting
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Submit pixel data to the current day's canvas.
    /// @param tokenId  The Brush NFT token ID authorising the paint action.
    /// @param pixels   Encoded pixel data (off-chain rendering handles interpretation).
    function paint(uint256 tokenId, bytes calldata pixels) public {
        require(startedAt != 0, "Not started");
        require(brushes.ownerOf(tokenId) == msg.sender, "Not your brush");

        uint256 day = today();
        uint256 pixelCount = pixels.length / 3; // each pixel = 3 bytes (x, y, color index)

        Canvas storage canvas = canvases[day];
        canvas.totalContributions += pixelCount;
        canvas.contributions[msg.sender] += pixelCount;
        canvas.brushUsed[tokenId] += pixelCount;

        emit Painted(day, tokenId, msg.sender, pixels);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Core: minting
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Mint open-edition NFTs for one or more completed days.
    /// @param days   Array of day indices to mint from.
    /// @param amounts  Corresponding number of tokens to mint per day.
    function mint(uint256[] calldata daysList, uint256[] calldata amounts) public payable {
        require(startedAt != 0, "Not started");
        require(daysList.length == amounts.length, "Length mismatch");

        uint256 totalCost = 0;
        uint256 currentDay = today();

        for (uint256 i = 0; i < daysList.length; i++) {
            uint256 day = daysList[i];
            require(day < currentDay, "Day not complete");
            require(amounts[i] > 0, "Zero amount");

            uint256 cost = openEditionPrice * amounts[i];
            totalCost += cost;

            uint256 ownerCut = (cost * ownerFeePartsPerMillion) / 1_000_000;
            uint256 artistCut = cost - ownerCut;

            ownerEarned += ownerCut;
            canvases[day].totalRaised += artistCut;

            _mint(msg.sender, day, amounts[i], "");
            emit Minted(day, msg.sender, amounts[i]);
            emit ArtistsEarned(day, artistCut);
        }

        require(msg.value == totalCost, "Wrong ETH amount");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Core: artist withdrawal
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Artists claim their pro-rata share of ETH raised from a completed day.
    /// @param day   The day index to claim earnings for.
    function authorWithdraw(uint256 day) public {
        require(day < today(), "Day not complete");

        Canvas storage canvas = canvases[day];
        uint256 contributions = canvas.contributions[msg.sender];
        require(contributions > 0, "No contributions");

        uint256 amount = (canvas.totalRaised * contributions) / canvas.totalContributions;
        require(amount > 0, "Nothing to withdraw");

        // Zero out before transfer to prevent re-entrancy
        canvas.contributions[msg.sender] = 0;

        payable(msg.sender).transfer(amount);
        emit ArtistWithdraw(day, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Returns the current day index (0-based, advances every epochDuration seconds).
    function today() public view returns (uint256) {
        require(startedAt != 0, "Not started");
        return (block.timestamp - startedAt) / epochDuration;
    }

    /// @notice Returns an artist's pixel contribution count for a given day.
    function contributions(uint256 day, address author) public view returns (uint256) {
        return canvases[day].contributions[author];
    }

    /// @notice Returns how many pixels a specific Brush token painted on a given day.
    function brushUsed(uint256 day, uint256 tokenId) public view returns (uint256) {
        return canvases[day].brushUsed[tokenId];
    }

    /// @notice ERC-1155 metadata URI — returns the BasePaint API endpoint.
    function uri(uint256 id) public pure override returns (string memory) {
        return string(abi.encodePacked("https://basepaint.xyz/api/art/", _toString(id)));
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Internal utilities
    // ─────────────────────────────────────────────────────────────────────

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
