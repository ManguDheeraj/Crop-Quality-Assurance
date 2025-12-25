// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title CropQualityAdvanced
 * @notice Final Hackathon Version - Stable OpenZeppelin v4.9
 */

// importing specific stable versions to prevent "Abstract Contract" errors
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/access/AccessControl.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/security/ReentrancyGuard.sol";

contract CropQualityAdvanced is AccessControl, ReentrancyGuard {
    // Roles
    bytes32 public constant ADMIN_ROLE    = DEFAULT_ADMIN_ROLE;
    bytes32 public constant LAB_ROLE      = keccak256("LAB_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant ORACLE_ROLE   = keccak256("ORACLE_ROLE");
    bytes32 public constant SENSOR_ROLE   = keccak256("SENSOR_ROLE");

    // Auto-increment id
    uint256 private _nextReportId = 1;

    // Crop classification enum
    enum Grade { Unknown, A, B, C } 

    // Pricing parameters
    struct PriceParams {
        uint256 basePrice;          
        uint256 moisturePenalty;    
        uint8 moistureThreshold;    
        uint256 impurityPenalty;    
        uint256 impurityDivisor;    
        uint256 grainBonusDiv;      
        uint256 regionMultiplierScale; 
    }

    PriceParams public params;

    // Classification thresholds
    struct GradeThresholds {
        uint8 maxMoistureA;
        uint16 maxImpurityA;   
        uint16 minGrainSizeA;  
        uint8 maxMoistureB;
        uint16 maxImpurityB;
        uint16 minGrainSizeB;
    }

    GradeThresholds public gradeThresholds;

    // Region Data
    mapping(bytes32 => uint256) private _regionBasePrice; 
    mapping(bytes32 => uint256) private _regionMultiplier; 

    // Main Report Struct
    struct TestReport {
        uint256 reportId;
        address farmer;
        bytes32 cropType;
        bytes32 region;
        string ipfsCid;
        uint256 timestamp;
        uint8 moisture;
        uint16 impurity;
        uint16 grainSize;
        uint256 suggestedPrice;
        Grade classification;
        address lab;
        bool disputed;
        bool exists;
    }

    // IoT Data Struct
    struct SensorData {
        uint256 sensorRecordId;
        bytes32 sensorId;
        bytes32 region;
        string ipfsCid;
        uint256 timestamp;
        address sender;
    }

    // Storage Mappings
    mapping(uint256 => TestReport) private _reports;
    mapping(address => uint256[]) private _farmerReports;
    mapping(uint256 => SensorData) private _sensorRecords;
    uint256 private _nextSensorRecordId = 1;

    // Events - Optimized to prevent Stack Too Deep
    event LabAuthorized(address indexed lab, address indexed admin, bool authorized);
    
    event ReportRecorded(
        uint256 indexed reportId,
        address indexed farmer,
        address indexed lab,
        // REMOVED heavy strings/bytes from index to fix stack error
        string ipfsCid,
        uint256 suggestedPrice,
        uint8 moisture,
        uint16 impurity,
        uint16 grainSize,
        uint8 classification
    );

    event SensorDataRecorded(uint256 indexed sensorRecordId, bytes32 indexed sensorId, string ipfsCid);

    // Errors
    error NotAuthorized();
    error InvalidInput();
    error ReportNotFound();

    // Modifiers
    modifier onlyLab() {
        if (!hasRole(LAB_ROLE, msg.sender)) revert NotAuthorized();
        _;
    }

    constructor() {
        _setupRole(ADMIN_ROLE, msg.sender);
        
        // Grant deployer LAB_ROLE for easy testing
        _setupRole(LAB_ROLE, msg.sender);

        // Set Defaults
        params = PriceParams({
            basePrice: 1000,
            moisturePenalty: 2,
            moistureThreshold: 12,
            impurityPenalty: 1,
            impurityDivisor: 100,
            grainBonusDiv: 10,
            regionMultiplierScale: 100
        });

        gradeThresholds = GradeThresholds({
            maxMoistureA: 12,
            maxImpurityA: 200,
            minGrainSizeA: 400,
            maxMoistureB: 15,
            maxImpurityB: 500,
            minGrainSizeB: 350
        });
    }

    // --- Core Functions ---

    function setLab(address lab, bool authorized) external onlyRole(ADMIN_ROLE) {
        if (authorized) grantRole(LAB_ROLE, lab); else revokeRole(LAB_ROLE, lab);
        emit LabAuthorized(lab, msg.sender, authorized);
    }

    function recordReport(
        address farmer,
        bytes32 cropType,
        bytes32 region,
        string calldata ipfsCid,
        uint8 moisture,
        uint16 impurity,
        uint16 grainSize
    ) external onlyLab nonReentrant returns (uint256) {
        if (farmer == address(0)) revert InvalidInput();

        uint256 id = _nextReportId++;

        // Logic inside struct creation to save stack space
        uint256 price = _computeSuggestedPrice(moisture, impurity, grainSize, region);
        Grade grade = _computeClassification(moisture, impurity, grainSize);

        TestReport memory r = TestReport({
            reportId: id,
            farmer: farmer,
            cropType: cropType,
            region: region,
            ipfsCid: ipfsCid,
            timestamp: block.timestamp,
            moisture: moisture,
            impurity: impurity,
            grainSize: grainSize,
            suggestedPrice: price,
            classification: grade,
            lab: msg.sender,
            disputed: false,
            exists: true
        });

        _reports[id] = r;
        _farmerReports[farmer].push(id);

        emit ReportRecorded(
            id, 
            farmer, 
            msg.sender, 
            ipfsCid, 
            price, 
            moisture, 
            impurity, 
            grainSize, 
            uint8(grade)
        );
        
        return id;
    }

    // --- Read Functions ---

    function getReport(uint256 reportId) external view returns (TestReport memory) {
        return _reports[reportId];
    }

    // --- Internal Logic ---

    function _computeSuggestedPrice(uint8 moisture, uint16 impurity, uint16 grainSize, bytes32 region) internal view returns (uint256) {
        int256 price = int256(params.basePrice);

        if (moisture > params.moistureThreshold) {
            price -= int256(uint256(moisture - params.moistureThreshold) * params.moisturePenalty);
        }
        
        if (impurity > 0) {
            price -= int256((uint256(impurity) / params.impurityDivisor) * params.impurityPenalty);
        }

        if (grainSize > 400) {
            price += int256((uint256(grainSize) - 400) / params.grainBonusDiv);
        }

        if (price < 0) return 0;

        uint256 finalPrice = uint256(price);
        uint256 multiplier = _regionMultiplier[region];
        if (multiplier > 0) {
            finalPrice = (finalPrice * multiplier) / params.regionMultiplierScale;
        }

        return finalPrice;
    }

    function _computeClassification(uint8 moisture, uint16 impurity, uint16 grainSize) internal view returns (Grade) {
        if (moisture <= gradeThresholds.maxMoistureA && impurity <= gradeThresholds.maxImpurityA && grainSize >= gradeThresholds.minGrainSizeA) {
            return Grade.A;
        }
        if (moisture <= gradeThresholds.maxMoistureB && impurity <= gradeThresholds.maxImpurityB && grainSize >= gradeThresholds.minGrainSizeB) {
            return Grade.B;
        }
        return Grade.C;
    }
}