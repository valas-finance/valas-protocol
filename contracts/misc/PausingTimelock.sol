pragma solidity 0.7.6;

import "../dependencies/openzeppelin/contracts/SafeMath.sol";

interface IConfigurator {
    function setPoolPause(bool val) external;
}

// Modified from Compound Timelock Admin
// https://raw.githubusercontent.com/compound-finance/compound-protocol/master/contracts/Timelock.sol
contract PausingTimelock {
    using SafeMath for uint;

    event NewAdmin(address indexed newAdmin);
    event NewPendingAdmin(address indexed newPendingAdmin);
    event NewEmergencyAdmin(address indexed newEmergencyAdmin);
    event NewPendingEmergencyAdmin(address indexed newPendingEmergencyAdmin);
    event NewDelay(uint indexed newDelay);
    event CancelTransaction(bytes32 indexed txHash, address indexed target, uint value, string signature, bytes data, uint eta);
    event ExecuteTransaction(bytes32 indexed txHash, address indexed target, uint value, string signature, bytes data, uint eta);
    event QueueTransaction(bytes32 indexed txHash, address indexed target, uint value, string signature, bytes data, uint eta);

    uint public constant GRACE_PERIOD = 14 days;
    uint public constant MINIMUM_DELAY = 2 days;
    uint public constant MAXIMUM_DELAY = 30 days;

    IConfigurator public immutable configurator;

    address public admin;
    address public pendingAdmin;
    address public emergencyAdmin;
    address public pendingEmergencyAdmin;
    uint public delay;
    uint public pauseCount;
    bool public isPaused;

    mapping (bytes32 => bool) public queuedTransactions;

    constructor(address admin_, address emergencyAdmin_, uint delay_, address configurator_) {
        require(delay_ >= MINIMUM_DELAY, "Timelock::constructor: Delay must exceed minimum delay.");
        require(delay_ <= MAXIMUM_DELAY, "Timelock::setDelay: Delay must not exceed maximum delay.");

        admin = admin_;
        emergencyAdmin = emergencyAdmin_;
        delay = delay_;
        configurator = IConfigurator(configurator_);
    }

    receive() external payable { }

    function setDelay(uint delay_) public {
        require(msg.sender == address(this), "Timelock::setDelay: Call must come from Timelock.");
        require(delay_ >= MINIMUM_DELAY, "Timelock::setDelay: Delay must exceed minimum delay.");
        require(delay_ <= MAXIMUM_DELAY, "Timelock::setDelay: Delay must not exceed maximum delay.");
        delay = delay_;

        emit NewDelay(delay);
    }

    function acceptAdmin() public {
        require(msg.sender == pendingAdmin, "Timelock::acceptAdmin: Call must come from pendingAdmin.");
        admin = msg.sender;
        pendingAdmin = address(0);

        emit NewAdmin(admin);
    }

    function setPendingAdmin(address pendingAdmin_) public {
        require(msg.sender == address(this), "Timelock::setPendingAdmin: Call must come from Timelock.");
        pendingAdmin = pendingAdmin_;

        emit NewPendingAdmin(pendingAdmin);
    }

    function acceptEmergencyAdmin() public {
        require(msg.sender == pendingEmergencyAdmin, "Timelock::acceptEmergencyAdmin: Call must come from pendingEmergencyAdmin.");
        emergencyAdmin = msg.sender;
        pendingEmergencyAdmin = address(0);

        emit NewEmergencyAdmin(emergencyAdmin);
    }

    function setPendingEmergencyAdmin(address pendingEmergencyAdmin_) public {
        require(msg.sender == address(this), "Timelock::setPendingEmergencyAdmin: Call must come from Timelock.");
        pendingEmergencyAdmin = pendingEmergencyAdmin_;

        emit NewPendingEmergencyAdmin(pendingEmergencyAdmin_);
    }

    function queueTransaction(address target, uint value, string memory signature, bytes memory data, uint eta) public returns (bytes32) {
        if (isPaused) {
            require(msg.sender == emergencyAdmin, "Timelock::queueTransaction: Call must come from emergency admin.");
        }
        else {
            require(msg.sender == admin, "Timelock::queueTransaction: Call must come from admin.");
        }
        
        require(eta >= getBlockTimestamp().add(delay), "Timelock::queueTransaction: Estimated execution block must satisfy delay.");

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta, pauseCount));
        queuedTransactions[txHash] = true;

        emit QueueTransaction(txHash, target, value, signature, data, eta);
        return txHash;
    }

    function cancelTransaction(address target, uint value, string memory signature, bytes memory data, uint eta, uint _pauseCount) public {
        require(msg.sender == admin, "Timelock::cancelTransaction: Call must come from admin.");

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta, _pauseCount));
        queuedTransactions[txHash] = false;

        emit CancelTransaction(txHash, target, value, signature, data, eta);
    }

    function executeTransaction(address target, uint value, string memory signature, bytes memory data, uint eta) public payable returns (bytes memory) {
        if (isPaused) {
            require(msg.sender == emergencyAdmin, "Timelock::executeTransaction: Call must come from emergency admin.");
        }
        else {
            require(msg.sender == admin, "Timelock::executeTransaction: Call must come from admin.");
        }

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta, pauseCount));
        require(queuedTransactions[txHash], "Timelock::executeTransaction: Transaction hasn't been queued.");
        require(getBlockTimestamp() >= eta, "Timelock::executeTransaction: Transaction hasn't surpassed time lock.");
        require(getBlockTimestamp() <= eta.add(GRACE_PERIOD), "Timelock::executeTransaction: Transaction is stale.");

        queuedTransactions[txHash] = false;

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        require(success, "Timelock::executeTransaction: Transaction execution reverted.");

        emit ExecuteTransaction(txHash, target, value, signature, data, eta);

        return returnData;
    }

    function setPoolPause(bool val) external {
        require(msg.sender == admin, "Timelock::setPoolPause: Call must come from admin.");
        require(isPaused != val, "Timelock::setPoolPause: Unchanged pause status.");
        if (val) {
            pauseCount += 1;
        }
        isPaused = val;
        configurator.setPoolPause(val);
    }

    function getBlockTimestamp() internal view returns (uint) {
        // solium-disable-next-line security/no-block-members
        return block.timestamp;
    }
}
