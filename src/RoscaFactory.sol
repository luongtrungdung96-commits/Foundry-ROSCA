// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RoscaCircle} from "./RoscaCircle.sol";

/**
 * @title  RoscaFactory
 * @notice Nhà máy tạo dây hụi. Hoàn toàn TRUSTLESS:
 *         - Không owner, không admin
 *         - Không thu phí
 *         - Không giữ tiền
 *         - Không có quyền can thiệp vào circle con
 */
contract RoscaFactory {
    address public immutable USDC;

    address[] public circles;
    mapping(address => address[]) public circlesOf;

    struct CreateParams {
        uint256 amountPerRound;
        uint256 collateralAmount;
        uint256 joinPeriod;
        uint256 depositPeriod;
        uint256 biddingPeriod;
        bool    isFixedSchedule;
    }

    event CircleCreated(
        address indexed circle,
        address indexed creator,
        bool    isFixedSchedule,
        uint256 amountPerRound,
        uint256 collateralAmount
    );

    constructor(address _usdc) {
        require(_usdc != address(0), "Invalid USDC");
        USDC = _usdc;
    }

    function createCircle(CreateParams calldata p) external returns (address circle) {
        circle = address(new RoscaCircle(
            msg.sender,
            USDC,
            p.amountPerRound,
            p.collateralAmount,
            p.joinPeriod,
            p.depositPeriod,
            p.biddingPeriod,
            p.isFixedSchedule
        ));

        circles.push(circle);
        circlesOf[msg.sender].push(circle);

        emit CircleCreated(circle, msg.sender, p.isFixedSchedule, p.amountPerRound, p.collateralAmount);
    }

    function circlesLength() external view returns (uint256) {
        return circles.length;
    }

    function circlesOfLength(address creator) external view returns (uint256) {
        return circlesOf[creator].length;
    }

    function getAllCircles() external view returns (address[] memory) {
        return circles;
    }

    function getCirclesOf(address creator) external view returns (address[] memory) {
        return circlesOf[creator];
    }
}