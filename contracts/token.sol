// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Administrable is Ownable {

    mapping (address => bool) public admins;

    event AdminAdded(address added);
    event AdminRemoved(address removed);

    // Only allow an admin to call a function

    modifier onlyAdmin {
        require(admins[_msgSender()] || owner() == _msgSender(), "Administrable: caller is not an admin");
        _;
    }

    // Set an account as an admin

    function addAdmin(address admin) external onlyOwner {
        require(!admins[admin], "Administrable: address is already an admin");
        admins[admin] = true;
        emit AdminAdded(admin);
    }

    // Remove an admin from admins

    function removeAdmin(address admin) external onlyOwner {
        require(admins[admin], "Administrable: address is not an admin");
        delete admins[admin];
        emit AdminRemoved(admin);
    }

}

contract CupDAOToken is ERC20Votes, Administrable {

    constructor() ERC20("cupDAO", "CUP") ERC20Permit("CUP") {
    }

    // Mint amount of CUP to account

    function mint(address account, uint256 amount) external onlyAdmin {
        _mint(account, amount);
    }

    // Burn CUP from caller

    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    // Burn CUP from account with approval

    function burnFrom(address account, uint256 amount) external {
        uint256 currentAllowance = allowance(account, _msgSender());
        require(currentAllowance >= amount, "ERC20: burn amount exceeds allowance");
        unchecked {
            _approve(account, _msgSender(), currentAllowance - amount);
        }
        _burn(account, amount);
    }

}
