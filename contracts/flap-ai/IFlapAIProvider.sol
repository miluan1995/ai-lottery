// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFlapAIProvider {
    struct Model { string name; uint256 price; bool enabled; }
    enum RequestStatus { NONE, PENDING, FULFILLED, UNDELIVERED, REFUNDED }
    struct Request {
        address consumer; uint16 modelId; uint8 numOfChoices; uint64 timestamp;
        uint128 feePaid; RequestStatus status; uint8 choice; bytes14 reserved;
    }
    function reason(uint256 modelId, string calldata prompt, uint8 numOfChoices) external payable returns (uint256 requestId);
    function getModel(uint256 modelId) external view returns (Model memory);
    function getReasoningCid(uint256 requestId) external view returns (string memory);
    function getRequest(uint256 requestId) external view returns (Request memory);
}

abstract contract FlapAIConsumerBase {
    error FlapAIConsumerOnlyProvider();
    error FlapAIConsumerUnsupportedChain(uint256 chainId);

    function lastRequestId() public view virtual returns (uint256);
    function _fulfillReasoning(uint256 requestId, uint8 choice) internal virtual;
    function _onFlapAIRequestRefunded(uint256 requestId) internal virtual;

    function _getFlapAIProvider() internal view virtual returns (address) {
        uint256 id = block.chainid;
        if (id == 56) return 0xaEe3a7Ca6fe6b53f6c32a3e8407eC5A9dF8B7E39;
        if (id == 97) return 0xFBeE0a1C921f6f4DadfAdd102b8276175D1b518D;
        revert FlapAIConsumerUnsupportedChain(id);
    }

    function fulfillReasoning(uint256 requestId, uint8 choice) external {
        if (msg.sender != _getFlapAIProvider()) revert FlapAIConsumerOnlyProvider();
        _fulfillReasoning(requestId, choice);
    }

    function onFlapAIRequestRefunded(uint256 requestId) external payable {
        if (msg.sender != _getFlapAIProvider()) revert FlapAIConsumerOnlyProvider();
        _onFlapAIRequestRefunded(requestId);
    }
}
