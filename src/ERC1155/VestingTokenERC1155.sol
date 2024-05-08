// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC20, SafeERC20} from "../../contracts/token/ERC20/utils/SafeERC20.sol";
// import {Initializable} from "../contracts/proxy/utils/Initializable.sol";
// import {Initializable} from     "../../upgradeable/contracts/proxy/utils/Initializable.sol";
import {Initializable, ERC20Upgradeable, ContextUpgradeable} from "../../upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
// import {ERC20} from "../contracts/token/ERC20/ERC20.sol";
import {Vesting, Schedule} from "./IVestingToken.sol";


// import {IERC1155} from "./IERC1155.sol";
import {IERC1155MetadataURI, IERC1155} from "./extensions/IERC1155MetadataURI.sol";
import {ERC1155Utils, IERC1155Errors} from "./utils/ERC1155Utils.sol";
// import {Context} from "../../contracts/utils/Context.sol";
// import {ContextUpgradeable, Initializable} from "../../upgradeable/contracts/utils/ContextUpgradeable.sol";
import {IERC165, ERC165} from "../../contracts/utils/introspection/ERC165.sol";
import {Arrays} from "../../contracts/utils/Arrays.sol";
// import {IERC1155Errors} from "../../contracts/interfaces/draft-IERC6093.sol";

/**
 * @title Контракт share-токена (вестинг-токен)
 * @notice Отвечает за логику блокировки/разблокировки средств
 * @dev Код предоставлен исключительно в ознакомительных целях и не протестирован
 * Из контракта убрано все лишнее, включая некоторые проверки, геттеры/сеттеры и события
 */
contract VestingTokenERC1155 is ContextUpgradeable, ERC165, Initializable, ERC20Upgradeable, 
IERC1155, IERC1155MetadataURI, IERC1155Errors {
    
// ContextUpgradeable, ERC165, IERC1155, IERC1155MetadataURI, IERC1155Errors, Initializable, ERC20Upgradeable {
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINTS = 10_000;

    address private _minter;
    address private _vestingManager;
    IERC20 private _baseToken;
    Vesting private _vesting;
    uint256 private _initialLockedSupply;


    using Arrays for uint256[];
    using Arrays for address[];

    mapping(uint256 id => mapping(address account => uint256)) private _balances;

    mapping(address account => mapping(address operator => bool)) private _operatorApprovals;

    // Used as the URI for all token types by relying on ID substitution, e.g. https://token-cdn-domain/{id}.json
    string private _uri;

    constructor(string memory uri_) {
        _setURI(uri_);
        _disableInitializers();
    }
    // constructor() {
    //     _disableInitializers();
    // }

    mapping(address => uint256) private _initialLocked;
    mapping(address => uint256) private _released;

    // region - Errors

    /////////////////////
    //      Errors     //
    /////////////////////

    error OnlyMinter();
    error OnlyVestingManager();
    error NotEnoughTokensToClaim();
    error StartTimeAlreadyElapsed();
    error CliffBeforeStartTime();
    error IncorrectSchedulePortions();
    error IncorrectScheduleTime(uint256 incorrectTime);
    error TransfersNotAllowed();
    error MintingAfterCliffIsForbidden();

    // endregion

    // region - Modifiers

    modifier onlyMinter() {
        if (msg.sender != _minter) {
            revert OnlyMinter();
        }

        _;
    }

    modifier onlyVestingManager() {
        if (msg.sender != _vestingManager) {
            revert OnlyVestingManager();
        }

        _;
    }

    // endregion

    // region - Initialize

    /**
     * @notice Так как это прокси, нужно выполнить инициализацию
     * @dev Создается и инициализируется только контрактом VestingManager
     */
    function initialize(string calldata name, string calldata symbol, address minter, address baseToken)
        public
        initializer
    {
        __ERC20_init(name, symbol);

        _minter = minter;
        _baseToken = IERC20(baseToken);
        _vestingManager = msg.sender;
    }

    // endregion

    // region - Set vesting schedule

    /**
     * @notice Установка расписания также выполняется контрактом VestingManager
     * @dev Здесь важно проверить что расписание было передано корректное
     */
    function setVestingSchedule(uint256 startTime, uint256 cliff, Schedule[] calldata schedule)
        external
        onlyVestingManager
    {
        uint256 scheduleLength = schedule.length;

        _checkVestingSchedule(startTime, cliff, schedule, scheduleLength);

        _vesting.startTime = startTime;
        _vesting.cliff = cliff;

        for (uint256 i = 0; i < scheduleLength; i++) {
            _vesting.schedule.push(schedule[i]);
        }
    }

    function _checkVestingSchedule(
        uint256 startTime,
        uint256 cliff,
        Schedule[] calldata schedule,
        uint256 scheduleLength
    ) private view {
        if (startTime < block.timestamp) {
            revert StartTimeAlreadyElapsed();
        }

        if (startTime > cliff) {
            revert CliffBeforeStartTime();
        }

        uint256 totalPercent;

        for (uint256 i = 0; i < scheduleLength; i++) {
            totalPercent += schedule[i].portion;

            bool isEndTimeOutOfOrder = (i != 0) && schedule[i - 1].endTime >= schedule[i].endTime;

            if (cliff >= schedule[i].endTime || isEndTimeOutOfOrder) {
                revert IncorrectScheduleTime(schedule[i].endTime);
            }
        }

        if (totalPercent != BASIS_POINTS) {
            revert IncorrectSchedulePortions();
        }
    }

    // endregion

    // region - Mint

    /**
     * @notice Списываем токен который будем блокировать и минтим share-токен
     */
    function mint(address to, uint256 amount) external onlyMinter {
        if (block.timestamp >= _vesting.cliff) {
            revert MintingAfterCliffIsForbidden();
        }

        _baseToken.safeTransferFrom(msg.sender, address(this), amount);

        _mint(to, amount);

        _initialLocked[to] += amount;
        _initialLockedSupply += amount;
    }

    // endregion

    // region - Claim

    /**
     * @notice Сжигаем share-токен и переводим бенефициару разблокированные базовые токены
     */
    function claim() external {
        uint256 releasable = availableBalanceOf(msg.sender);

        if (releasable == 0) {
            revert NotEnoughTokensToClaim();
        }

        _released[msg.sender] += releasable;

        _burn(msg.sender, releasable);
        _baseToken.safeTransfer(msg.sender, releasable);
    }

    // endregion

    // region - Vesting getters

    function getVestingSchedule() public view returns (Vesting memory) {
        return _vesting;
    }

    function unlockedSupply() external view returns (uint256) {
        return _totalUnlocked();
    }

    function lockedSupply() external view returns (uint256) {
        return _initialLockedSupply - _totalUnlocked();
    }

    function availableBalanceOf(address account) public view returns (uint256 releasable) {
        releasable = _unlockedOf(account) - _released[account];
    }

    // endregion

    // region - Private functions

    function _unlockedOf(address account) private view returns (uint256) {
        return _computeUnlocked(_initialLocked[account], block.timestamp);
    }

    function _totalUnlocked() private view returns (uint256) {
        return _computeUnlocked(_initialLockedSupply, block.timestamp);
    }

    /**
     * @notice Основная функция для расчета разблокированных токенов
     * @dev Проверяется сколько прошло полных периодов и сколько времени прошло
     * после последнего полного периода.
     */
    function _computeUnlocked(uint256 lockedTokens, uint256 time) private view returns (uint256 unlockedTokens) {
        if (time < _vesting.cliff) {
            return 0;
        }

        uint256 currentPeriodStart = _vesting.cliff;
        Schedule[] memory schedule = _vesting.schedule;
        uint256 scheduleLength = schedule.length;

        for (uint256 i = 0; i < scheduleLength; i++) {
            Schedule memory currentPeriod = schedule[i];
            uint256 currentPeriodEnd = currentPeriod.endTime;
            uint256 currentPeriodPortion = currentPeriod.portion;

            if (time < currentPeriodEnd) {
                uint256 elapsedPeriodTime = time - currentPeriodStart;
                uint256 periodDuration = currentPeriodEnd - currentPeriodStart;

                unlockedTokens +=
                    (lockedTokens * elapsedPeriodTime * currentPeriodPortion) / (periodDuration * BASIS_POINTS);
                break;
            } else {
                unlockedTokens += (lockedTokens * currentPeriodPortion) / BASIS_POINTS;
                currentPeriodStart = currentPeriodEnd;
            }
        }
    }

    /**
     * @notice Трансферить токены нельзя, только минтить и сжигать
     */
    // function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
    //     super._beforeTokenTransfer(from, to, amount);

    //     if (from != address(0) && to != address(0)) {
    //         revert TransfersNotAllowed();
    //     }
    // }

    // endregion




   /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IERC1155).interfaceId ||
            interfaceId == type(IERC1155MetadataURI).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev See {IERC1155MetadataURI-uri}.
     *
     * This implementation returns the same URI for *all* token types. It relies
     * on the token type ID substitution mechanism
     * https://eips.ethereum.org/EIPS/eip-1155#metadata[defined in the ERC].
     *
     * Clients calling this function must replace the `\{id\}` substring with the
     * actual token type ID.
     */
    function uri(uint256 /* id */) public view virtual returns (string memory) {
        return _uri;
    }

    /**
     * @dev See {IERC1155-balanceOf}.
     */
    function balanceOf(address account, uint256 id) public view virtual returns (uint256) {
        return _balances[id][account];
    }

    /**
     * @dev See {IERC1155-balanceOfBatch}.
     *
     * Requirements:
     *
     * - `accounts` and `ids` must have the same length.
     */
    function balanceOfBatch(
        address[] memory accounts,
        uint256[] memory ids
    ) public view virtual returns (uint256[] memory) {
        if (accounts.length != ids.length) {
            revert ERC1155InvalidArrayLength(ids.length, accounts.length);
        }

        uint256[] memory batchBalances = new uint256[](accounts.length);

        for (uint256 i = 0; i < accounts.length; ++i) {
            batchBalances[i] = balanceOf(accounts.unsafeMemoryAccess(i), ids.unsafeMemoryAccess(i));
        }

        return batchBalances;
    }

    /**
     * @dev See {IERC1155-setApprovalForAll}.
     */
    function setApprovalForAll(address operator, bool approved) public virtual {
        _setApprovalForAll(_msgSender(), operator, approved);
    }

    /**
     * @dev See {IERC1155-isApprovedForAll}.
     */
    function isApprovedForAll(address account, address operator) public view virtual returns (bool) {
        return _operatorApprovals[account][operator];
    }

    /**
     * @dev See {IERC1155-safeTransferFrom}.
     */
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes memory data) public virtual {
        address sender = _msgSender();
        if (from != sender && !isApprovedForAll(from, sender)) {
            revert ERC1155MissingApprovalForAll(sender, from);
        }
        _safeTransferFrom(from, to, id, value, data);
    }

    /**
     * @dev See {IERC1155-safeBatchTransferFrom}.
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public virtual {
        address sender = _msgSender();
        if (from != sender && !isApprovedForAll(from, sender)) {
            revert ERC1155MissingApprovalForAll(sender, from);
        }
        _safeBatchTransferFrom(from, to, ids, values, data);
    }

    /**
     * @dev Transfers a `value` amount of tokens of type `id` from `from` to `to`. Will mint (or burn) if `from`
     * (or `to`) is the zero address.
     *
     * Emits a {TransferSingle} event if the arrays contain one element, and {TransferBatch} otherwise.
     *
     * Requirements:
     *
     * - If `to` refers to a smart contract, it must implement either {IERC1155Receiver-onERC1155Received}
     *   or {IERC1155Receiver-onERC1155BatchReceived} and return the acceptance magic value.
     * - `ids` and `values` must have the same length.
     *
     * NOTE: The ERC-1155 acceptance check is not performed in this function. See {_updateWithAcceptanceCheck} instead.
     */
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal virtual {
        if (ids.length != values.length) {
            revert ERC1155InvalidArrayLength(ids.length, values.length);
        }

        address operator = _msgSender();

        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids.unsafeMemoryAccess(i);
            uint256 value = values.unsafeMemoryAccess(i);

            if (from != address(0)) {
                uint256 fromBalance = _balances[id][from];
                if (fromBalance < value) {
                    revert ERC1155InsufficientBalance(from, fromBalance, value, id);
                }
                unchecked {
                    // Overflow not possible: value <= fromBalance
                    _balances[id][from] = fromBalance - value;
                }
            }

            if (to != address(0)) {
                _balances[id][to] += value;
            }
        }

        if (ids.length == 1) {
            uint256 id = ids.unsafeMemoryAccess(0);
            uint256 value = values.unsafeMemoryAccess(0);
            emit TransferSingle(operator, from, to, id, value);
        } else {
            emit TransferBatch(operator, from, to, ids, values);
        }
    }

    /**
     * @dev Version of {_update} that performs the token acceptance check by calling
     * {IERC1155Receiver-onERC1155Received} or {IERC1155Receiver-onERC1155BatchReceived} on the receiver address if it
     * contains code (eg. is a smart contract at the moment of execution).
     *
     * IMPORTANT: Overriding this function is discouraged because it poses a reentrancy risk from the receiver. So any
     * update to the contract state after this function would break the check-effect-interaction pattern. Consider
     * overriding {_update} instead.
     */
    function _updateWithAcceptanceCheck(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) internal virtual {
        _update(from, to, ids, values);
        if (to != address(0)) {
            address operator = _msgSender();
            if (ids.length == 1) {
                uint256 id = ids.unsafeMemoryAccess(0);
                uint256 value = values.unsafeMemoryAccess(0);
                ERC1155Utils.checkOnERC1155Received(operator, from, to, id, value, data);
            } else {
                ERC1155Utils.checkOnERC1155BatchReceived(operator, from, to, ids, values, data);
            }
        }
    }

    /**
     * @dev Transfers a `value` tokens of token type `id` from `from` to `to`.
     *
     * Emits a {TransferSingle} event.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - `from` must have a balance of tokens of type `id` of at least `value` amount.
     * - If `to` refers to a smart contract, it must implement {IERC1155Receiver-onERC1155Received} and return the
     * acceptance magic value.
     */
    function _safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes memory data) internal {
        if (to == address(0)) {
            revert ERC1155InvalidReceiver(address(0));
        }
        if (from == address(0)) {
            revert ERC1155InvalidSender(address(0));
        }
        (uint256[] memory ids, uint256[] memory values) = _asSingletonArrays(id, value);
        _updateWithAcceptanceCheck(from, to, ids, values, data);
    }

    /**
     * @dev xref:ROOT:erc1155.adoc#batch-operations[Batched] version of {_safeTransferFrom}.
     *
     * Emits a {TransferBatch} event.
     *
     * Requirements:
     *
     * - If `to` refers to a smart contract, it must implement {IERC1155Receiver-onERC1155BatchReceived} and return the
     * acceptance magic value.
     * - `ids` and `values` must have the same length.
     */
    function _safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) internal {
        if (to == address(0)) {
            revert ERC1155InvalidReceiver(address(0));
        }
        if (from == address(0)) {
            revert ERC1155InvalidSender(address(0));
        }
        _updateWithAcceptanceCheck(from, to, ids, values, data);
    }

    /**
     * @dev Sets a new URI for all token types, by relying on the token type ID
     * substitution mechanism
     * https://eips.ethereum.org/EIPS/eip-1155#metadata[defined in the ERC].
     *
     * By this mechanism, any occurrence of the `\{id\}` substring in either the
     * URI or any of the values in the JSON file at said URI will be replaced by
     * clients with the token type ID.
     *
     * For example, the `https://token-cdn-domain/\{id\}.json` URI would be
     * interpreted by clients as
     * `https://token-cdn-domain/000000000000000000000000000000000000000000000000000000000004cce0.json`
     * for token type ID 0x4cce0.
     *
     * See {uri}.
     *
     * Because these URIs cannot be meaningfully represented by the {URI} event,
     * this function emits no events.
     */
    function _setURI(string memory newuri) internal virtual {
        _uri = newuri;
    }

    /**
     * @dev Creates a `value` amount of tokens of type `id`, and assigns them to `to`.
     *
     * Emits a {TransferSingle} event.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - If `to` refers to a smart contract, it must implement {IERC1155Receiver-onERC1155Received} and return the
     * acceptance magic value.
     */
    function _mint(address to, uint256 id, uint256 value, bytes memory data) internal {
        if (to == address(0)) {
            revert ERC1155InvalidReceiver(address(0));
        }
        (uint256[] memory ids, uint256[] memory values) = _asSingletonArrays(id, value);
        _updateWithAcceptanceCheck(address(0), to, ids, values, data);
    }

    /**
     * @dev xref:ROOT:erc1155.adoc#batch-operations[Batched] version of {_mint}.
     *
     * Emits a {TransferBatch} event.
     *
     * Requirements:
     *
     * - `ids` and `values` must have the same length.
     * - `to` cannot be the zero address.
     * - If `to` refers to a smart contract, it must implement {IERC1155Receiver-onERC1155BatchReceived} and return the
     * acceptance magic value.
     */
    function _mintBatch(address to, uint256[] memory ids, uint256[] memory values, bytes memory data) internal {
        if (to == address(0)) {
            revert ERC1155InvalidReceiver(address(0));
        }
        _updateWithAcceptanceCheck(address(0), to, ids, values, data);
    }

    /**
     * @dev Destroys a `value` amount of tokens of type `id` from `from`
     *
     * Emits a {TransferSingle} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `from` must have at least `value` amount of tokens of type `id`.
     */
    function _burn(address from, uint256 id, uint256 value) internal {
        if (from == address(0)) {
            revert ERC1155InvalidSender(address(0));
        }
        (uint256[] memory ids, uint256[] memory values) = _asSingletonArrays(id, value);
        _updateWithAcceptanceCheck(from, address(0), ids, values, "");
    }

    /**
     * @dev xref:ROOT:erc1155.adoc#batch-operations[Batched] version of {_burn}.
     *
     * Emits a {TransferBatch} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `from` must have at least `value` amount of tokens of type `id`.
     * - `ids` and `values` must have the same length.
     */
    function _burnBatch(address from, uint256[] memory ids, uint256[] memory values) internal {
        if (from == address(0)) {
            revert ERC1155InvalidSender(address(0));
        }
        _updateWithAcceptanceCheck(from, address(0), ids, values, "");
    }

    /**
     * @dev Approve `operator` to operate on all of `owner` tokens
     *
     * Emits an {ApprovalForAll} event.
     *
     * Requirements:
     *
     * - `operator` cannot be the zero address.
     */
    function _setApprovalForAll(address owner, address operator, bool approved) internal virtual {
        if (operator == address(0)) {
            revert ERC1155InvalidOperator(address(0));
        }
        _operatorApprovals[owner][operator] = approved;
        emit ApprovalForAll(owner, operator, approved);
    }

    /**
     * @dev Creates an array in memory with only one value for each of the elements provided.
     */
    function _asSingletonArrays(
        uint256 element1,
        uint256 element2
    ) private pure returns (uint256[] memory array1, uint256[] memory array2) {
        /// @solidity memory-safe-assembly
        assembly {
            // Load the free memory pointer
            array1 := mload(0x40)
            // Set array length to 1
            mstore(array1, 1)
            // Store the single element at the next word after the length (where content starts)
            mstore(add(array1, 0x20), element1)

            // Repeat for next array locating it right after the first array
            array2 := add(array1, 0x40)
            mstore(array2, 1)
            mstore(add(array2, 0x20), element2)

            // Update the free memory pointer by pointing after the second array
            mstore(0x40, add(array2, 0x40))
        }
    }


}
