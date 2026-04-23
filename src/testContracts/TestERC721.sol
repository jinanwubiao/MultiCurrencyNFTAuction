// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TestERC721 is ERC721Enumerable, Ownable {
    string private _tokenUri;

    constructor() ERC721("Troll", "Troll") Ownable(msg.sender) {}

    function mint(address to, uint256 tokenId) external onlyOwner {
        _mint(to, tokenId);
    }

    function tokenURI(uint256) public view override returns (string memory) {
        return _tokenUri;
    }

    function setTokenURI(string memory newTokenURI) external onlyOwner {
        _tokenUri = newTokenURI;
    }
}
