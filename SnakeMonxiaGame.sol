// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract MonxiaCoin is ERC20, Ownable {
    constructor() ERC20("MonxiaCoin", "MCN") Ownable(msg.sender) {
        _mint(msg.sender, 1000000 * 10**decimals()); // Initial supply to owner
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function burnFrom(address account, uint256 amount) public {
        _burn(account, amount);
    }
}

contract SnakeMonxiaGame is ERC721, ERC721URIStorage, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    using Strings for uint256;

    Counters.Counter private _tokenIdCounter;

    MonxiaCoin public coins;

    // Pricing
    uint256 public constant CLASSIC_MINT_PRICE = 0.01 ether;
    uint256 public constant SPECIAL_MINT_PRICE = 1 ether;
    uint256 public constant SKIN_PRICE = 10 * 10**18; // 10 coins (18 decimals)

    // Base URI for metadata
    string private _baseTokenURI = "https://example-metadata-host.com/snake/";

    // Snake struct
    struct SnakeAttributes {
        uint8 speed; // 1-10
        uint8 hearts; // 1-10
        uint8 length; // 3-13 (3 + 0-10 bonus)
        uint8 skin; // 0-4
        bool isClassic; // For upgrades
    }
    mapping(uint256 => SnakeAttributes) public snakeAttributes;
    mapping(uint256 => bool) public isClassicSnake; // Redundant but for clarity

    // Leaderboard: Top 100 per mode (0-4)
    mapping(uint8 => address[100]) public topPlayers;
    mapping(uint8 => uint256[100]) public topScores;
    mapping(uint8 => mapping(address => uint256)) public personalBests;

    // Upgrade costs base: 1 coin for level 2, doubles per level
    uint256 public constant BASE_UPGRADE_COST = 1 * 10**18; // 1 coin

    // Events
    event SnakeMinted(uint256 tokenId, address owner, SnakeAttributes attrs);
    event SnakeUpgraded(uint256 tokenId, string attr, uint8 newValue);
    event SkinApplied(uint256 tokenId, uint8 skin);
    event ScoreSubmitted(address player, uint8 mode, uint256 score, uint256 coinsEarned);

    constructor() ERC721("SnakeMonxia", "SNK") Ownable(msg.sender) {
        coins = new MonxiaCoin();
    }

    // Mint Classic (upgradable)
    function mintClassic(address to) public payable nonReentrant returns (uint256) {
        require(msg.value >= CLASSIC_MINT_PRICE, "Insufficient payment");
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _safeMint(to, tokenId);
        SnakeAttributes memory attrs = SnakeAttributes(1, 1, 3, 0, true);
        snakeAttributes[tokenId] = attrs;
        isClassicSnake[tokenId] = true;
        refundExcess(msg.value, CLASSIC_MINT_PRICE, to);
        emit SnakeMinted(tokenId, to, attrs);
        return tokenId;
    }

    // Mint Specialized
    function mintFastSnake(address to) public payable nonReentrant returns (uint256) {
        require(msg.value >= SPECIAL_MINT_PRICE, "Insufficient payment");
        return _mintSpecial(to, SnakeAttributes(10, 1, 3, 0, false));
    }

    function mintHeartySnake(address to) public payable nonReentrant returns (uint256) {
        require(msg.value >= SPECIAL_MINT_PRICE, "Insufficient payment");
        return _mintSpecial(to, SnakeAttributes(1, 10, 3, 0, false));
    }

    function mintLongSnake(address to) public payable nonReentrant returns (uint256) {
        require(msg.value >= SPECIAL_MINT_PRICE, "Insufficient payment");
        return _mintSpecial(to, SnakeAttributes(1, 1, 13, 0, false));
    }

    function _mintSpecial(address to, SnakeAttributes memory attrs) internal nonReentrant returns (uint256) {
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _safeMint(to, tokenId);
        snakeAttributes[tokenId] = attrs;
        refundExcess(msg.value, SPECIAL_MINT_PRICE, to);
        emit SnakeMinted(tokenId, to, attrs);
        return tokenId;
    }

    // Upgrades (only classic)
    function upgradeSpeed(uint256 tokenId, uint8 newSpeed) public nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(isClassicSnake[tokenId], "Only classic");
        require(newSpeed > snakeAttributes[tokenId].speed && newSpeed <= 10, "Invalid level");
        uint256 cost = calculateUpgradeCost(snakeAttributes[tokenId].speed, newSpeed);
        coins.burnFrom(msg.sender, cost); // Transfer coins
        snakeAttributes[tokenId].speed = newSpeed;
        emit SnakeUpgraded(tokenId, "speed", newSpeed);
    }

    function upgradeHearts(uint256 tokenId, uint8 newHearts) public nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(isClassicSnake[tokenId], "Only classic");
        require(newHearts > snakeAttributes[tokenId].hearts && newHearts <= 10, "Invalid level");
        uint256 cost = calculateUpgradeCost(snakeAttributes[tokenId].hearts, newHearts);
        coins.burnFrom(msg.sender, cost);
        snakeAttributes[tokenId].hearts = newHearts;
        emit SnakeUpgraded(tokenId, "hearts", newHearts);
    }

    function upgradeLength(uint256 tokenId, uint8 newLengthBonus) public nonReentrant { // newLength = 3 + bonus (0-10)
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        require(isClassicSnake[tokenId], "Only classic");
        uint8 currentBonus = snakeAttributes[tokenId].length - 3;
        require(newLengthBonus > currentBonus && newLengthBonus <= 10, "Invalid level");
        uint256 cost = calculateUpgradeCost(currentBonus, newLengthBonus);
        coins.burnFrom(msg.sender, cost);
        snakeAttributes[tokenId].length = 3 + newLengthBonus;
        emit SnakeUpgraded(tokenId, "length", 3 + newLengthBonus);
    }

    function calculateUpgradeCost(uint8 current, uint8 target) public pure returns (uint256) {
        uint256 cost = 0;
        uint256 levelCost = BASE_UPGRADE_COST;
        for (uint8 i = current + 1; i <= target; i++) {
            cost += levelCost;
            levelCost *= 2;
        }
        return cost;
    }

    // Skins
    function applySkin(uint256 tokenId, uint8 skinId) public nonReentrant {
        require(skinId <= 4, "Invalid skin");
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        coins.burnFrom(msg.sender, SKIN_PRICE);
        snakeAttributes[tokenId].skin = skinId;
        emit SkinApplied(tokenId, skinId);
    }

    // Score Submission & Coins (auto-called by frontend)
    function submitScore(uint8 mode, uint256 score) public nonReentrant {
        require(mode <= 4, "Invalid mode");
        uint256 prevBest = personalBests[mode][msg.sender];
        if (score > prevBest) {
            personalBests[mode][msg.sender] = score;
            _updateLeaderboard(mode, msg.sender, score);
            uint256 coinsEarned = (score / 10) * 10**18; // 0.1 coin per point, scaled
            coins.mint(msg.sender, coinsEarned);
            emit ScoreSubmitted(msg.sender, mode, score, coinsEarned);
        }
    }

    function _updateLeaderboard(uint8 mode, address player, uint256 score) internal {
        // iterate slots; treat empty slots (score == 0) as available
        for (uint256 i = 0; i < 100; i++) {
            if (topScores[mode][i] == 0 || score > topScores[mode][i]) {
                // Shift down
                for (uint256 j = 99; j > i; j--) {
                    topPlayers[mode][j] = topPlayers[mode][j - 1];
                    topScores[mode][j] = topScores[mode][j - 1];
                }
                topPlayers[mode][i] = player;
                topScores[mode][i] = score;
                return;
            }
        }
    }

    // Utils
    function refundExcess(uint256 paid, uint256 required, address to) internal {
        uint256 refundAmount = paid - required;
        if (refundAmount > 0) {
            (bool success, ) = payable(to).call{value: refundAmount}("");
            require(success, "Refund failed");
        }
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        require(ownerOf(tokenId) != address(0), "ERC721Metadata: URI query for nonexistent token");

        SnakeAttributes memory attrs = snakeAttributes[tokenId];

        string memory json = string(
            abi.encodePacked(
                '{"name":"Snake #',
                tokenId.toString(),
                '","description":"Snake Game Character","image":"',
                _baseTokenURI,
                tokenId.toString(),
                '.png",',
                '"attributes":[',
                    '{"trait_type":"Speed","value":',
                    Strings.toString(attrs.speed),
                    '},',
                    '{"trait_type":"Hearts","value":',
                    Strings.toString(attrs.hearts),
                    '},',
                    '{"trait_type":"Length","value":',
                    Strings.toString(attrs.length),
                    '},',
                    '{"trait_type":"Skin","value":',
                    Strings.toString(attrs.skin),
                    '}',
                ']}'
            )
        );

        return bytes(_baseTokenURI).length > 0 ? string(abi.encodePacked(_baseTokenURI, tokenId.toString(), ".json")) : json;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // Return how many leaderboard entries exist for a mode
    function topScoresLength(uint8 mode) public view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < 100; i++) {
            if (topPlayers[mode][i] == address(0)) break;
            count++;
        }
        return count;
    }

    // Return a leaderboard entry
    function topScoresAt(uint8 mode, uint256 index) public view returns (address player, uint256 score) {
        require(index < 100, "Out of range");
        return (topPlayers[mode][index], topScores[mode][index]);
    }

    // Return full top list (for frontend)
    function getTopPlayers(uint8 mode) external view returns (address[100] memory players, uint256[100] memory scores) {
        return (topPlayers[mode], topScores[mode]);
    }

    // Return personal best for user
    function getPersonalBest(uint8 mode, address player) external view returns (uint256) {
        return personalBests[mode][player];
    }

}
