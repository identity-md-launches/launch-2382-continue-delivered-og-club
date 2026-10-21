// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Cell-by-cell oracle. No production masks or bitmap calculations are used to decide acceptance.
library LaunchLayoutModel {
    struct Board {
        bool[256] floor;
        bool[32] walls;
        bool[32] designs;
    }

    struct Placement {
        uint8 w;
        uint8 h;
        bool wall;
        uint8 x;
        uint8 y;
        uint8 rot;
        uint8 design;
    }

    function inside(uint8 level, uint256 x, uint256 y) internal pure returns (bool) {
        if (level == 1) return x < 10 && y < 10;
        if (level == 2) return x < 14 && y < 10;
        if (level == 3) return (x < 14 && y < 10) || (x < 10 && y < 16);
        return x < 16 && y < 16;
    }

    function length(uint8 level, uint8 side) internal pure returns (uint256) {
        return side == 0 ? (level == 1 ? 10 : level == 4 ? 16 : 14) : (level < 3 ? 10 : 16);
    }

    function valid(Board memory b, uint8 level, Placement memory p) internal pure returns (bool) {
        if (b.designs[p.design]) return false;
        if (p.wall) {
            if (p.rot > 1 || p.y != 0 || uint256(p.x) + p.w > length(level, p.rot)) return false;
            for (uint256 pos = p.x; pos < uint256(p.x) + p.w; ++pos) {
                if ((p.rot == 1 && pos == 4) || b.walls[p.rot * 16 + pos]) return false;
            }
        } else {
            if (p.rot > 3) return false;
            uint256 w = p.rot % 2 == 1 ? p.h : p.w;
            uint256 h = p.rot % 2 == 1 ? p.w : p.h;
            for (uint256 y = p.y; y < uint256(p.y) + h; ++y) {
                for (uint256 x = p.x; x < uint256(p.x) + w; ++x) {
                    if (!inside(level, x, y) || (y == 4 && x < 2) || b.floor[y * 16 + x]) return false;
                }
            }
        }
        return true;
    }

    function occupy(Board memory b, Placement memory p) internal pure returns (Board memory) {
        b.designs[p.design] = true;
        if (p.wall) {
            for (uint256 pos = p.x; pos < uint256(p.x) + p.w; ++pos) {
                b.walls[p.rot * 16 + pos] = true;
            }
        } else {
            uint256 w = p.rot % 2 == 1 ? p.h : p.w;
            uint256 h = p.rot % 2 == 1 ? p.w : p.h;
            for (uint256 y = p.y; y < uint256(p.y) + h; ++y) {
                for (uint256 x = p.x; x < uint256(p.x) + w; ++x) {
                    b.floor[y * 16 + x] = true;
                }
            }
        }
        return b;
    }
}
