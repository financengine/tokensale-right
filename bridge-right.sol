pragma solidity ^0.4.15;

library Authorities {
    function contains (address[] self, address value) internal returns (bool) {
        for (uint i = 0; i < self.length; i++) {
            if (self[i] == value) {
                return true;
            }
        }
        return false;
    }

    function truncate (address[] storage self, uint len) internal {
        for (uint i = len; i < self.length; i++) {
            delete self[i];
        }
        self.length = len;
    }
}

library Utils {
    function toString (uint256 v) internal returns (string str) {
        // it is used only for small numbers
        bytes memory reversed = new bytes(8);
        uint i = 0;
        while (v != 0) {
            uint remainder = v % 10;
            v = v / 10;
            reversed[i++] = byte(48 + remainder);
        }
        bytes memory s = new bytes(i);
        for (uint j = 0; j < i; j++) {
            s[j] = reversed[i - j - 1];
        }
        str = string(s);
    }
}

library Signer {
    function signer (bytes signature, bytes message) internal returns (address) {
        require(signature.length == 65);
        bytes32 r;
        bytes32 s;
        bytes1 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := mload(add(signature, 0x60))
        }
        return ecrecover(hash(message), uint8(v), r, s);
    }

    function hash (bytes message) internal returns (bytes32) {
        bytes memory prefix = "\x19Ethereum Signed Message:\n";
        return sha3(prefix, Utils.toString(message.length), message);
    }
}


contract ERC20 {
    function transfer(address to, uint256 value) public returns (bool);
    function transferFrom(address from, address to, uint256 value) public returns (bool);
    function allowance(address owner, address spender) public constant returns (uint256);
}

contract ForeignBridge {
    using Authorities for address[];

    struct SignaturesCollection {
        /// Signed message.
        bytes message;
        /// Authorities who signed the message.
        address[] signed;
        /// Signaturs
        bytes[] signatures;
    }

    /// Number of authorities signatures required to withdraw the money.
    ///
    /// Must be lesser than number of authorities.
    uint public requiredSignatures;

    /// Contract authorities.
    address[] public authorities;

    /// Pending deposits and authorities who confirmed them
    mapping (bytes32 => address[]) deposits;

    /// List of authorities confirmed to set up ERC-20 token address
    mapping (address => address[]) public token_address;
    
    /// Token to work with
    ERC20 public erc20token;
    
    /// Event created on money deposit.
    event TokenAddress(address token);
    
    /// Pending signatures and authorities who confirmed them
    mapping (bytes32 => SignaturesCollection) signatures;

    /// Event created on money deposit.
    event Deposit(address recipient, uint value);

    /// Event created on money withdraw.
    event Withdraw(address recipient, uint value);

    /// Collected signatures which should be relayed to home chain.
    event CollectedSignatures(address authority, bytes32 messageHash);

    /// Constructor.
    function ForeignBridge(uint n, address[] a) {
        require(n != 0);
        require(n <= a.length);
        requiredSignatures = n;
        authorities = a;
    }

    /// Multisig authority validation
    modifier onlyAuthority () {
        require(authorities.contains(msg.sender));
        _;
    }

    /// Set up the token address.
    ///
    /// token address (address)
    function setTokenAddress (ERC20 token) public onlyAuthority() {
        // Protect duplicated request
        require(!token_address[token].contains(msg.sender));

        token_address[token].push(msg.sender);
        // TODO: this may cause troubles if requriedSignatures len is changed
        if (token_address[token].length == requiredSignatures) {
            erc20token = ERC20(token);
            TokenAddress(token);
        }
    }

    /// Used to deposit money to the contract.
    ///
    /// deposit recipient (bytes20)
    /// deposit value (uint)
    /// mainnet transaction hash (bytes32) // to avoid transaction duplication
    function deposit (address recipient, uint value, bytes32 transactionHash) onlyAuthority() {
        // Protection from misbehaing authority
        var hash = sha3(recipient, value, transactionHash);

        // Duplicated deposits
        require(!deposits[hash].contains(msg.sender));

        deposits[hash].push(msg.sender);
        // TODO: this may cause troubles if requriedSignatures len is changed
        if (deposits[hash].length == requiredSignatures) {
            erc20token.transfer(recipient, value);
            Deposit(recipient, value);
        }
    }

    /// Withdraw money
    function withdraw(address recipient, uint value) public {
        require(erc20token.allowance(msg.sender, this) >= value); 
        erc20token.transferFrom(msg.sender, this, value);
        Withdraw(recipient, value);
    }

    /// Should be used as sync tool
    ///
    /// Message is a message that should be relayed to main chain once authorities sign it.
    ///
    /// for withdraw message contains:
    /// withdrawal recipient (bytes20)
    /// withdrawal value (uint)
    /// foreign transaction hash (bytes32) // to avoid transaction duplication
    function submitSignature (bytes signature, bytes message) onlyAuthority() {
        // Validate submited signatures
        require(Signer.signer(signature, message) == msg.sender);

        // Valid withdraw message must have 84 bytes
        require(message.length == 84);
        var hash = sha3(message);

        // Duplicated signatures
        require(!signatures[hash].signed.contains(msg.sender));
        signatures[hash].message = message;
        signatures[hash].signed.push(msg.sender);
        signatures[hash].signatures.push(signature);

        // TODO: this may cause troubles if requriedSignatures len is changed
        if (signatures[hash].signed.length == requiredSignatures) {
            CollectedSignatures(msg.sender, hash);
        }
    }

    /// Get signature
    function signature (bytes32 hash, uint index) constant returns (bytes) {
        return signatures[hash].signatures[index];
    }

    /// Get message
    function message (bytes32 hash) constant returns (bytes) {
        return signatures[hash].message;
    }
}