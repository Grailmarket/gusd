// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {
    MessagingParams,
    MessagingFee,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IGUSD} from "./interfaces/IGUSD.sol";
import {OApp} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OAppOptionsType3} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {OAppPreCrimeSimulator} from "@layerzerolabs/oapp-evm/contracts/precrime/OAppPreCrimeSimulator.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency} from "./libraries/Currency.sol";

contract GUSD is IGUSD, Ownable, ERC20, OApp, OAppPreCrimeSimulator, OAppOptionsType3 {
    uint8 public constant GUSD_CONVERSION_RATE = 100; // mint price * 100 = 1000;
    uint8 private constant MSG_TYPE_SEND = 1;
    uint8 private constant MSG_TYPE_ADD_PEERS = 2;
    uint16 private constant BASIS_POINT = 10_000; // 100%
    uint16 public constant MAX_PROTOCOL_FEE = 1_000; // 10%
    uint256 public constant LOT_AMOUNT = 1_000 * 10 ** 6; // 1000 GUSD
    address private constant GRAIL_BURNER_ACCOUNT = 0x000000000000000000000000000000000000dEaD;

    /// @dev Message type offset
    uint256 private constant MSG_TYPE_OFFSET = 1;

    /// @dev Bytes offset for send credit payload
    uint256 private constant SEND_TO_OFFSET = 33;
    uint256 private constant SEND_AMOUNT_OFFSET = 41;

    /// @notice Provides a conversion rate when swapping between denominations of SD and LD
    uint256 public immutable decimalConversionRate;

    /// @dev store stable coin accepted
    Currency public immutable currency;

    /// @dev store the mint price per lot amount
    uint256 public immutable mintPrice;

    /// @dev store the grail market minter address
    address public immutable minter;

    /// @dev store the governance chain endpoint ID
    uint32 public immutable governanceEid;

    /// @dev keep track of accrued mint fees
    uint256 public mintFeesAccrued;

    /// @dev store the minting fee in BPS
    uint16 public mintFeeBps;

    constructor(address _owner, Currency _currency, address _minter, uint32 _governanceEid, address _endpoint)
        ERC20("Grail Dollar", "GUSD")
        Ownable(_owner)
        OApp(_endpoint, _owner)
    {
        currency = _currency;
        minter = _minter;
        // Hack to allow Gnosis native xDAI
        uint8 _decimals = _currency.isNative() ? 18 : _currency.decimals();

        governanceEid = _governanceEid;
        decimalConversionRate = 10 ** (_decimals - decimals());
        mintPrice = 10 * 10 ** _decimals; // 10 USD
        mintFeeBps = 300; // 3 %

        emit AddMinter(_minter);
    }

    /// @inheritdoc IGUSD
    function mint(uint8 lotSize) external payable override {
        uint256 totalCost = mintPrice * lotSize;
        uint256 protocolFee;
        uint256 lotAmount = LOT_AMOUNT * lotSize;

        if (mintFeeBps > 0) {
            protocolFee = (totalCost * mintFeeBps) / BASIS_POINT;
            totalCost += protocolFee;
            mintFeesAccrued += protocolFee;
        }

        // pull the minting cost
        if (currency.isNative()) {
            if (msg.value < totalCost) revert InsufficientFee();
        } else {
            currency.safeTransferFrom(msg.sender, address(this), totalCost);
        }

        // credit the user balance
        _mint(msg.sender, lotAmount);
        emit Mint(msg.sender, lotAmount, lotSize, totalCost);
    }

    /// @inheritdoc IGUSD
    function redeem(uint256 amount) external override {
        uint256 balance = currency.balanceOfSelf();

        if (amount == 0 || amount < GUSD_CONVERSION_RATE) revert InvalidAmount();
        uint256 amountLD = _previewRedeem(amount);

        if (balance < amountLD) revert InsufficientLiquidity();

        /// @dev Burns GUSD before redeeming
        _burn(msg.sender, amount);
        currency.transfer(msg.sender, amountLD);

        emit Redeem(msg.sender, amount, amountLD);
    }

    /// @inheritdoc IGUSD
    function credit(address account, uint256 amount) external override returns (bool) {
        if (msg.sender != minter) revert OnlyMinterAllowed();

        _mint(account, amount);
        emit Credit(account, amount);

        return true;
    }

    /// @inheritdoc IGUSD
    function debit(address account, uint256 amount) external override returns (bool) {
        if (msg.sender != minter) revert OnlyMinterAllowed();

        _burn(account, amount);
        emit Debit(account, amount);

        return true;
    }

    /// @inheritdoc IGUSD
    function recoverToken(Currency recoveredCurrency, address recipient, uint256 amount) external override onlyOwner {
        if (currency == recoveredCurrency) revert CannotRecoverCurrency();

        if (amount == 0) {
            amount = recoveredCurrency.balanceOfSelf();
        }

        recoveredCurrency.transfer(recipient, amount);
    }

    /// @inheritdoc IGUSD
    function addPeers(PeerConfig[] calldata peerConfigs, bytes calldata extraOptions)
        external
        payable
        override
        onlyOwner
    {
        /// @notice Ensures the config request can only originate from the governance chain
        if (endpoint.eid() != governanceEid) revert FunctionDisabled();
        bytes memory _message = abi.encodePacked(MSG_TYPE_ADD_PEERS, abi.encode(peerConfigs));

        uint256 len = peerConfigs.length;
        for (uint256 i = 0; i < len; i++) {
            PeerConfig memory peer = peerConfigs[i];
            _setPeer(peer.eid, peer.peer);

            bytes memory _options = combineOptions(peer.eid, MSG_TYPE_ADD_PEERS, extraOptions);
            MessagingFee memory _fee = _quote(peer.eid, _message, _options, false);

            _lzSend(peer.eid, _message, _options, _fee, payable(msg.sender));
        }
    }

    /// @inheritdoc IGUSD
    function collectMintFee(address recipient, uint256 amount) external override onlyOwner {
        if (amount > mintFeesAccrued) revert AmountExceedsAccruedFee();
        uint256 amountCollected;

        amountCollected = (amount == 0) ? mintFeesAccrued : amount;
        mintFeesAccrued -= amountCollected;

        // credit the recipient
        currency.transfer(recipient, amountCollected);
        emit CollectMintFee(msg.sender, recipient, amountCollected);
    }

    /// @inheritdoc IGUSD
    function setMintFee(uint16 fee) external override onlyOwner {
        // ensure fee is moderate
        if (fee > MAX_PROTOCOL_FEE) revert FeeTooLarge(fee);

        mintFeeBps = fee;
        emit SetMintFee(fee);
    }

    /// @inheritdoc IGUSD
    function send(SendParam calldata _sendParam, MessagingFee calldata _fee, address _refundAddress)
        external
        payable
        override
        returns (MessagingReceipt memory msgReceipt)
    {
        // Burn the user GUSD before making transfer
        _burn(msg.sender, _sendParam.amount);
        bytes memory _options = combineOptions(_sendParam.dstEid, MSG_TYPE_SEND, _sendParam.extraOptions);
        bytes memory _message = abi.encodePacked(MSG_TYPE_SEND, _sendParam.to, uint64(_sendParam.amount));

        msgReceipt = _lzSend(_sendParam.dstEid, _message, _options, _fee, _refundAddress);
        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, _sendParam.amount);
    }

    function setPeer(uint32, bytes32) public pure override {
        revert FunctionDisabled();
    }

    function isPeer(uint32 _eid, bytes32 _peer) public view override returns (bool) {
        return peers[_eid] == _peer;
    }

    /// @inheritdoc IGUSD
    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken)
        external
        view
        override
        returns (MessagingFee memory fee)
    {
        bytes memory _options = combineOptions(_sendParam.dstEid, MSG_TYPE_SEND, _sendParam.extraOptions);
        bytes memory _message = abi.encodePacked(MSG_TYPE_SEND, _sendParam.to, uint64(_sendParam.amount));
        fee = _quote(_sendParam.dstEid, _message, _options, _payInLzToken);
    }

    /// @inheritdoc IGUSD
    function quoteMint(uint8 lotSize) external view override returns (uint256 totalCost) {
        totalCost = mintPrice * lotSize;
        if (mintFeeBps > 0) totalCost += (totalCost * mintFeeBps) / BASIS_POINT;
    }

    /// @inheritdoc IGUSD
    function quoteAddPeers(PeerConfig[] calldata peerConfigs, bytes calldata extraOptions)
        external
        view
        override
        returns (MessagingFee memory fee)
    {
        bytes memory _message = abi.encodePacked(MSG_TYPE_ADD_PEERS, abi.encode(peerConfigs));

        for (uint256 i = 0; i < peerConfigs.length; i++) {
            bytes memory _options = combineOptions(peerConfigs[i].eid, MSG_TYPE_ADD_PEERS, extraOptions);
            MessagingFee memory _fee = endpoint.quote(
                MessagingParams(peerConfigs[i].eid, peerConfigs[i].peer, _message, _options, false), address(this)
            );

            fee.nativeFee += _fee.nativeFee;
        }
    }

    /// @inheritdoc IGUSD
    function getBalances(address account)
        external
        view
        override
        returns (uint256 currencyBalance, uint256 gusdBalance)
    {
        currencyBalance = currency.balanceOf(account);
        gusdBalance = balanceOf(account);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @dev Internal function to convert an amount from shared decimals into local decimals.
     * @param _amountIn The amount in GUSD decimals {6 decimals}.
     * @return amountOut The amount in local decimals.
     */
    function _previewRedeem(uint256 _amountIn) private view returns (uint256 amountOut) {
        return (_amountIn / GUSD_CONVERSION_RATE) * decimalConversionRate;
    }

    /**
     * @dev Converts an address to bytes32.
     * @param _addr The address to convert.
     * @return The bytes32 representation of the address.
     */
    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    /**
     * @dev Converts bytes32 to an address.
     * @param _b The bytes32 value to convert.
     * @return The address representation of bytes32.
     */
    function _bytes32ToAddress(bytes32 _b) internal pure returns (address) {
        return address(uint160(uint256(_b)));
    }

    function _payNative(uint256 _nativeFee) internal override returns (uint256 nativeFee) {
        if (msg.value < _nativeFee) revert NotEnoughNative(msg.value);
        return _nativeFee;
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address, /* _executor */
        bytes calldata /* _extraData */
    ) internal override {
        uint8 msgType = uint8(bytes1(_message[:MSG_TYPE_OFFSET]));

        if (msgType == MSG_TYPE_SEND) {
            _receiveSend(_origin, _message, _guid);
        } else if (msgType == MSG_TYPE_ADD_PEERS) {
            _receivePeers(_origin, _message);
        }
    }

    function _lzReceiveSimulate(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal override {
        _lzReceive(_origin, _guid, _message, _executor, _extraData);
    }

    /**
     * @dev Receives and execute crediting instruction from trusted remote peer
     *
     * @param _origin the message origin sender contract and endpoint identifier
     * @param _message contains the amount and recipient address
     * @param _guid the received message unique ID
     */
    function _receiveSend(Origin calldata _origin, bytes calldata _message, bytes32 _guid) private {
        address to = _bytes32ToAddress(bytes32(_message[MSG_TYPE_OFFSET:SEND_TO_OFFSET]));
        uint64 amount = uint64(bytes8(_message[SEND_TO_OFFSET:SEND_AMOUNT_OFFSET]));

        _mint(to, amount);
        emit OFTReceived(_guid, _origin.srcEid, to, amount);
    }

    /**
     * @dev Allow consuming governance instructions from governance chain
     *
     * @param _origin struct containing origin contract address and endpoint ID
     * @param _message encoded message containing governance instruction
     */
    function _receivePeers(Origin calldata _origin, bytes calldata _message) private {
        // ensure message originated from manager chain
        if (_origin.srcEid != governanceEid) revert OnlyGovernanceChainAllowed();

        bytes memory payload = bytes(_message[MSG_TYPE_OFFSET:]);
        PeerConfig[] memory peerConfigs = abi.decode(payload, (PeerConfig[]));

        uint256 len = peerConfigs.length;
        for (uint256 i = 0; i < len; i++) {
            _setPeer(peerConfigs[i].eid, peerConfigs[i].peer);
        }
    }
}
