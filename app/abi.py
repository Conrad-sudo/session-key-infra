"""
Contract ABIs used across app/, extracted from app/artifacts/*.json so the
app doesn't need to read those files (or ship the artifacts/ directory) at
runtime. Each variable is named after its source file (IEntryPoint.json -> ientry_point).
"""

erc20_mock = [
  {
    "type": "constructor",
    "inputs": [
      { "name": "name", "type": "string", "internalType": "string" },
      { "name": "symbol", "type": "string", "internalType": "string" },
      { "name": "_decimals", "type": "uint8", "internalType": "uint8" }
    ],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "allowance",
    "inputs": [
      { "name": "owner", "type": "address", "internalType": "address" },
      { "name": "spender", "type": "address", "internalType": "address" }
    ],
    "outputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "approve",
    "inputs": [
      { "name": "spender", "type": "address", "internalType": "address" },
      { "name": "value", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [
      { "name": "", "type": "bool", "internalType": "bool" }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "balanceOf",
    "inputs": [
      { "name": "account", "type": "address", "internalType": "address" }
    ],
    "outputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "burn",
    "inputs": [
      { "name": "account", "type": "address", "internalType": "address" },
      { "name": "amount", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "decimals",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "uint8", "internalType": "uint8" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "mint",
    "inputs": [
      { "name": "account", "type": "address", "internalType": "address" },
      { "name": "amount", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "name",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "string", "internalType": "string" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "sendEth",
    "inputs": [],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "symbol",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "string", "internalType": "string" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalSupply",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "transfer",
    "inputs": [
      { "name": "to", "type": "address", "internalType": "address" },
      { "name": "value", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [
      { "name": "", "type": "bool", "internalType": "bool" }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "transferFrom",
    "inputs": [
      { "name": "from", "type": "address", "internalType": "address" },
      { "name": "to", "type": "address", "internalType": "address" },
      { "name": "value", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [
      { "name": "", "type": "bool", "internalType": "bool" }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "Approval",
    "inputs": [
      { "name": "owner", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "spender", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "value", "type": "uint256", "indexed": False, "internalType": "uint256" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "Transfer",
    "inputs": [
      { "name": "from", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "to", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "value", "type": "uint256", "indexed": False, "internalType": "uint256" }
    ],
    "anonymous": False
  },
  {
    "type": "error",
    "name": "ERC20InsufficientAllowance",
    "inputs": [
      { "name": "spender", "type": "address", "internalType": "address" },
      { "name": "allowance", "type": "uint256", "internalType": "uint256" },
      { "name": "needed", "type": "uint256", "internalType": "uint256" }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InsufficientBalance",
    "inputs": [
      { "name": "sender", "type": "address", "internalType": "address" },
      { "name": "balance", "type": "uint256", "internalType": "uint256" },
      { "name": "needed", "type": "uint256", "internalType": "uint256" }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InvalidApprover",
    "inputs": [
      { "name": "approver", "type": "address", "internalType": "address" }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InvalidReceiver",
    "inputs": [
      { "name": "receiver", "type": "address", "internalType": "address" }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InvalidSender",
    "inputs": [
      { "name": "sender", "type": "address", "internalType": "address" }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InvalidSpender",
    "inputs": [
      { "name": "spender", "type": "address", "internalType": "address" }
    ]
  }
]


ierc20_extended = [
  {
    "type": "function",
    "name": "allowance",
    "inputs": [
      { "name": "owner", "type": "address", "internalType": "address" },
      { "name": "spender", "type": "address", "internalType": "address" }
    ],
    "outputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "approve",
    "inputs": [
      { "name": "spender", "type": "address", "internalType": "address" },
      { "name": "value", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [
      { "name": "", "type": "bool", "internalType": "bool" }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "balanceOf",
    "inputs": [
      { "name": "account", "type": "address", "internalType": "address" }
    ],
    "outputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "decimals",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "uint8", "internalType": "uint8" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "name",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "string", "internalType": "string" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "symbol",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "string", "internalType": "string" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalSupply",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "transfer",
    "inputs": [
      { "name": "to", "type": "address", "internalType": "address" },
      { "name": "value", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [
      { "name": "", "type": "bool", "internalType": "bool" }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "transferFrom",
    "inputs": [
      { "name": "from", "type": "address", "internalType": "address" },
      { "name": "to", "type": "address", "internalType": "address" },
      { "name": "value", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [
      { "name": "", "type": "bool", "internalType": "bool" }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "Approval",
    "inputs": [
      { "name": "owner", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "spender", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "value", "type": "uint256", "indexed": False, "internalType": "uint256" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "Transfer",
    "inputs": [
      { "name": "from", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "to", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "value", "type": "uint256", "indexed": False, "internalType": "uint256" }
    ],
    "anonymous": False
  }
]


ientry_point = [
  {
    "type": "function",
    "name": "addStake",
    "inputs": [
      { "name": "unstakeDelaySec", "type": "uint32", "internalType": "uint32" }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "balanceOf",
    "inputs": [
      { "name": "account", "type": "address", "internalType": "address" }
    ],
    "outputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "delegateAndRevert",
    "inputs": [
      { "name": "target", "type": "address", "internalType": "address" },
      { "name": "data", "type": "bytes", "internalType": "bytes" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "depositTo",
    "inputs": [
      { "name": "account", "type": "address", "internalType": "address" }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "getCurrentUserOpHash",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "bytes32", "internalType": "bytes32" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getDepositInfo",
    "inputs": [
      { "name": "account", "type": "address", "internalType": "address" }
    ],
    "outputs": [
      { "name": "info", "type": "tuple", "internalType": "struct IStakeManager.DepositInfo", "components": [{'name': 'deposit', 'type': 'uint256', 'internalType': 'uint256'}, {'name': 'staked', 'type': 'bool', 'internalType': 'bool'}, {'name': 'stake', 'type': 'uint112', 'internalType': 'uint112'}, {'name': 'unstakeDelaySec', 'type': 'uint32', 'internalType': 'uint32'}, {'name': 'withdrawTime', 'type': 'uint48', 'internalType': 'uint48'}] }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getNonce",
    "inputs": [
      { "name": "sender", "type": "address", "internalType": "address" },
      { "name": "key", "type": "uint192", "internalType": "uint192" }
    ],
    "outputs": [
      { "name": "nonce", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getSenderAddress",
    "inputs": [
      { "name": "initCode", "type": "bytes", "internalType": "bytes" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getUserOpHash",
    "inputs": [
      { "name": "userOp", "type": "tuple", "internalType": "struct PackedUserOperation", "components": [{'name': 'sender', 'type': 'address', 'internalType': 'address'}, {'name': 'nonce', 'type': 'uint256', 'internalType': 'uint256'}, {'name': 'initCode', 'type': 'bytes', 'internalType': 'bytes'}, {'name': 'callData', 'type': 'bytes', 'internalType': 'bytes'}, {'name': 'accountGasLimits', 'type': 'bytes32', 'internalType': 'bytes32'}, {'name': 'preVerificationGas', 'type': 'uint256', 'internalType': 'uint256'}, {'name': 'gasFees', 'type': 'bytes32', 'internalType': 'bytes32'}, {'name': 'paymasterAndData', 'type': 'bytes', 'internalType': 'bytes'}, {'name': 'signature', 'type': 'bytes', 'internalType': 'bytes'}] }
    ],
    "outputs": [
      { "name": "", "type": "bytes32", "internalType": "bytes32" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "handleAggregatedOps",
    "inputs": [
      { "name": "opsPerAggregator", "type": "tuple[]", "internalType": "struct IEntryPoint.UserOpsPerAggregator[]", "components": [{'name': 'userOps', 'type': 'tuple[]', 'internalType': 'struct PackedUserOperation[]', 'components': [{'name': 'sender', 'type': 'address', 'internalType': 'address'}, {'name': 'nonce', 'type': 'uint256', 'internalType': 'uint256'}, {'name': 'initCode', 'type': 'bytes', 'internalType': 'bytes'}, {'name': 'callData', 'type': 'bytes', 'internalType': 'bytes'}, {'name': 'accountGasLimits', 'type': 'bytes32', 'internalType': 'bytes32'}, {'name': 'preVerificationGas', 'type': 'uint256', 'internalType': 'uint256'}, {'name': 'gasFees', 'type': 'bytes32', 'internalType': 'bytes32'}, {'name': 'paymasterAndData', 'type': 'bytes', 'internalType': 'bytes'}, {'name': 'signature', 'type': 'bytes', 'internalType': 'bytes'}]}, {'name': 'aggregator', 'type': 'address', 'internalType': 'contract IAggregator'}, {'name': 'signature', 'type': 'bytes', 'internalType': 'bytes'}] },
      { "name": "beneficiary", "type": "address", "internalType": "address payable" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "handleOps",
    "inputs": [
      { "name": "ops", "type": "tuple[]", "internalType": "struct PackedUserOperation[]", "components": [{'name': 'sender', 'type': 'address', 'internalType': 'address'}, {'name': 'nonce', 'type': 'uint256', 'internalType': 'uint256'}, {'name': 'initCode', 'type': 'bytes', 'internalType': 'bytes'}, {'name': 'callData', 'type': 'bytes', 'internalType': 'bytes'}, {'name': 'accountGasLimits', 'type': 'bytes32', 'internalType': 'bytes32'}, {'name': 'preVerificationGas', 'type': 'uint256', 'internalType': 'uint256'}, {'name': 'gasFees', 'type': 'bytes32', 'internalType': 'bytes32'}, {'name': 'paymasterAndData', 'type': 'bytes', 'internalType': 'bytes'}, {'name': 'signature', 'type': 'bytes', 'internalType': 'bytes'}] },
      { "name": "beneficiary", "type": "address", "internalType": "address payable" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "incrementNonce",
    "inputs": [
      { "name": "key", "type": "uint192", "internalType": "uint192" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "senderCreator",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "address", "internalType": "contract ISenderCreator" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "unlockStake",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "withdrawStake",
    "inputs": [
      { "name": "withdrawAddress", "type": "address", "internalType": "address payable" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "withdrawTo",
    "inputs": [
      { "name": "withdrawAddress", "type": "address", "internalType": "address payable" },
      { "name": "withdrawAmount", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "AccountDeployed",
    "inputs": [
      { "name": "userOpHash", "type": "bytes32", "indexed": True, "internalType": "bytes32" },
      { "name": "sender", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "factory", "type": "address", "indexed": False, "internalType": "address" },
      { "name": "paymaster", "type": "address", "indexed": False, "internalType": "address" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "BeforeExecution",
    "inputs": [],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "Deposited",
    "inputs": [
      { "name": "account", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "totalDeposit", "type": "uint256", "indexed": False, "internalType": "uint256" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "EIP7702AccountInitialized",
    "inputs": [
      { "name": "userOpHash", "type": "bytes32", "indexed": True, "internalType": "bytes32" },
      { "name": "sender", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "delegate", "type": "address", "indexed": True, "internalType": "address" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "IgnoredInitCode",
    "inputs": [
      { "name": "userOpHash", "type": "bytes32", "indexed": True, "internalType": "bytes32" },
      { "name": "sender", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "unusedFactory", "type": "address", "indexed": False, "internalType": "address" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "PostOpRevertReason",
    "inputs": [
      { "name": "userOpHash", "type": "bytes32", "indexed": True, "internalType": "bytes32" },
      { "name": "sender", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "nonce", "type": "uint256", "indexed": False, "internalType": "uint256" },
      { "name": "revertReason", "type": "bytes", "indexed": False, "internalType": "bytes" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "SignatureAggregatorChanged",
    "inputs": [
      { "name": "aggregator", "type": "address", "indexed": True, "internalType": "address" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "StakeLocked",
    "inputs": [
      { "name": "account", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "totalStaked", "type": "uint256", "indexed": False, "internalType": "uint256" },
      { "name": "unstakeDelaySec", "type": "uint256", "indexed": False, "internalType": "uint256" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "StakeUnlocked",
    "inputs": [
      { "name": "account", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "withdrawTime", "type": "uint256", "indexed": False, "internalType": "uint256" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "StakeWithdrawn",
    "inputs": [
      { "name": "account", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "withdrawAddress", "type": "address", "indexed": False, "internalType": "address" },
      { "name": "amount", "type": "uint256", "indexed": False, "internalType": "uint256" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "UserOperationEvent",
    "inputs": [
      { "name": "userOpHash", "type": "bytes32", "indexed": True, "internalType": "bytes32" },
      { "name": "sender", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "paymaster", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "nonce", "type": "uint256", "indexed": False, "internalType": "uint256" },
      { "name": "success", "type": "bool", "indexed": False, "internalType": "bool" },
      { "name": "actualGasCost", "type": "uint256", "indexed": False, "internalType": "uint256" },
      { "name": "actualGasUsed", "type": "uint256", "indexed": False, "internalType": "uint256" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "UserOperationPrefundTooLow",
    "inputs": [
      { "name": "userOpHash", "type": "bytes32", "indexed": True, "internalType": "bytes32" },
      { "name": "sender", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "nonce", "type": "uint256", "indexed": False, "internalType": "uint256" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "UserOperationRevertReason",
    "inputs": [
      { "name": "userOpHash", "type": "bytes32", "indexed": True, "internalType": "bytes32" },
      { "name": "sender", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "nonce", "type": "uint256", "indexed": False, "internalType": "uint256" },
      { "name": "revertReason", "type": "bytes", "indexed": False, "internalType": "bytes" }
    ],
    "anonymous": False
  },
  {
    "type": "event",
    "name": "Withdrawn",
    "inputs": [
      { "name": "account", "type": "address", "indexed": True, "internalType": "address" },
      { "name": "withdrawAddress", "type": "address", "indexed": False, "internalType": "address" },
      { "name": "amount", "type": "uint256", "indexed": False, "internalType": "uint256" }
    ],
    "anonymous": False
  },
  {
    "type": "error",
    "name": "DelegateAndRevert",
    "inputs": [
      { "name": "success", "type": "bool", "internalType": "bool" },
      { "name": "ret", "type": "bytes", "internalType": "bytes" }
    ]
  },
  {
    "type": "error",
    "name": "DepositWithdrawalFailed",
    "inputs": [
      { "name": "account", "type": "address", "internalType": "address" },
      { "name": "withdrawAddress", "type": "address", "internalType": "address" },
      { "name": "amount", "type": "uint256", "internalType": "uint256" },
      { "name": "revertReason", "type": "bytes", "internalType": "bytes" }
    ]
  },
  {
    "type": "error",
    "name": "FailedOp",
    "inputs": [
      { "name": "opIndex", "type": "uint256", "internalType": "uint256" },
      { "name": "reason", "type": "string", "internalType": "string" }
    ]
  },
  {
    "type": "error",
    "name": "FailedOpWithRevert",
    "inputs": [
      { "name": "opIndex", "type": "uint256", "internalType": "uint256" },
      { "name": "reason", "type": "string", "internalType": "string" },
      { "name": "inner", "type": "bytes", "internalType": "bytes" }
    ]
  },
  {
    "type": "error",
    "name": "FailedSendToBeneficiary",
    "inputs": [
      { "name": "beneficiary", "type": "address", "internalType": "address" },
      { "name": "amount", "type": "uint256", "internalType": "uint256" },
      { "name": "revertData", "type": "bytes", "internalType": "bytes" }
    ]
  },
  {
    "type": "error",
    "name": "InsufficientDeposit",
    "inputs": [
      { "name": "currentDeposit", "type": "uint256", "internalType": "uint256" },
      { "name": "withdrawAmount", "type": "uint256", "internalType": "uint256" }
    ]
  },
  {
    "type": "error",
    "name": "InternalFunction",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidBeneficiary",
    "inputs": [
      { "name": "beneficiary", "type": "address", "internalType": "address" }
    ]
  },
  {
    "type": "error",
    "name": "InvalidPaymaster",
    "inputs": [
      { "name": "paymaster", "type": "address", "internalType": "address" }
    ]
  },
  {
    "type": "error",
    "name": "InvalidPaymasterData",
    "inputs": [
      { "name": "paymasterAndDataLength", "type": "uint256", "internalType": "uint256" }
    ]
  },
  {
    "type": "error",
    "name": "InvalidStake",
    "inputs": [
      { "name": "msgValue", "type": "uint256", "internalType": "uint256" },
      { "name": "currentStake", "type": "uint256", "internalType": "uint256" }
    ]
  },
  {
    "type": "error",
    "name": "InvalidUnstakeDelay",
    "inputs": [
      { "name": "newUnstakeDelaySec", "type": "uint256", "internalType": "uint256" },
      { "name": "currentUnstakeDelaySec", "type": "uint256", "internalType": "uint256" }
    ]
  },
  {
    "type": "error",
    "name": "NotStaked",
    "inputs": [
      { "name": "currentStake", "type": "uint256", "internalType": "uint256" },
      { "name": "unstakeDelaySec", "type": "uint256", "internalType": "uint256" },
      { "name": "staked", "type": "bool", "internalType": "bool" }
    ]
  },
  {
    "type": "error",
    "name": "PostOpReverted",
    "inputs": [
      { "name": "returnData", "type": "bytes", "internalType": "bytes" }
    ]
  },
  {
    "type": "error",
    "name": "SenderAddressResult",
    "inputs": [
      { "name": "sender", "type": "address", "internalType": "address" }
    ]
  },
  {
    "type": "error",
    "name": "SignatureValidationFailed",
    "inputs": [
      { "name": "aggregator", "type": "address", "internalType": "address" }
    ]
  },
  {
    "type": "error",
    "name": "StakeNotUnlocked",
    "inputs": [
      { "name": "withdrawTime", "type": "uint256", "internalType": "uint256" },
      { "name": "blockTimestamp", "type": "uint256", "internalType": "uint256" }
    ]
  },
  {
    "type": "error",
    "name": "StakeWithdrawalFailed",
    "inputs": [
      { "name": "account", "type": "address", "internalType": "address" },
      { "name": "withdrawAddress", "type": "address", "internalType": "address" },
      { "name": "amount", "type": "uint256", "internalType": "uint256" },
      { "name": "revertReason", "type": "bytes", "internalType": "bytes" }
    ]
  },
  {
    "type": "error",
    "name": "WithdrawalNotDue",
    "inputs": [
      { "name": "withdrawTime", "type": "uint256", "internalType": "uint256" },
      { "name": "blockTimestamp", "type": "uint256", "internalType": "uint256" }
    ]
  }
]


ireputation_registry = [
  {
    "type": "function",
    "name": "getSummary",
    "inputs": [
      { "name": "agentId", "type": "uint256", "internalType": "uint256" },
      { "name": "clientAddresses", "type": "address[]", "internalType": "address[]" },
      { "name": "tag1", "type": "string", "internalType": "string" },
      { "name": "tag2", "type": "string", "internalType": "string" }
    ],
    "outputs": [
      { "name": "count", "type": "uint64", "internalType": "uint64" },
      { "name": "summaryValue", "type": "int128", "internalType": "int128" },
      { "name": "summaryValueDecimals", "type": "uint8", "internalType": "uint8" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "giveFeedback",
    "inputs": [
      { "name": "agentId", "type": "uint256", "internalType": "uint256" },
      { "name": "value", "type": "int128", "internalType": "int128" },
      { "name": "valueDecimals", "type": "uint8", "internalType": "uint8" },
      { "name": "tag1", "type": "string", "internalType": "string" },
      { "name": "tag2", "type": "string", "internalType": "string" },
      { "name": "endpoint", "type": "string", "internalType": "string" },
      { "name": "feedbackURI", "type": "string", "internalType": "string" },
      { "name": "feedbackHash", "type": "bytes32", "internalType": "bytes32" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "readAllFeedback",
    "inputs": [
      { "name": "agentId", "type": "uint256", "internalType": "uint256" },
      { "name": "clientAddresses", "type": "address[]", "internalType": "address[]" },
      { "name": "tag1", "type": "string", "internalType": "string" },
      { "name": "tag2", "type": "string", "internalType": "string" },
      { "name": "includeRevoked", "type": "bool", "internalType": "bool" }
    ],
    "outputs": [
      { "name": "clients", "type": "address[]", "internalType": "address[]" },
      { "name": "feedbackIndexes", "type": "uint64[]", "internalType": "uint64[]" },
      { "name": "values", "type": "int128[]", "internalType": "int128[]" },
      { "name": "valueDecimals", "type": "uint8[]", "internalType": "uint8[]" },
      { "name": "tag1s", "type": "string[]", "internalType": "string[]" },
      { "name": "tag2s", "type": "string[]", "internalType": "string[]" },
      { "name": "revokedStatuses", "type": "bool[]", "internalType": "bool[]" }
    ],
    "stateMutability": "view"
  }
]










mock_v3_aggregator = [
  {
    "type": "constructor",
    "inputs": [
      { "name": "_decimals", "type": "uint8", "internalType": "uint8" },
      { "name": "_initialAnswer", "type": "int256", "internalType": "int256" }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "decimals",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "uint8", "internalType": "uint8" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "description",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "string", "internalType": "string" }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "getAnswer",
    "inputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [
      { "name": "", "type": "int256", "internalType": "int256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getRoundData",
    "inputs": [
      { "name": "_roundId", "type": "uint80", "internalType": "uint80" }
    ],
    "outputs": [
      { "name": "roundId", "type": "uint80", "internalType": "uint80" },
      { "name": "answer", "type": "int256", "internalType": "int256" },
      { "name": "startedAt", "type": "uint256", "internalType": "uint256" },
      { "name": "updatedAt", "type": "uint256", "internalType": "uint256" },
      { "name": "answeredInRound", "type": "uint80", "internalType": "uint80" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getTimestamp",
    "inputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "latestAnswer",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "int256", "internalType": "int256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "latestRound",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "latestRoundData",
    "inputs": [],
    "outputs": [
      { "name": "roundId", "type": "uint80", "internalType": "uint80" },
      { "name": "answer", "type": "int256", "internalType": "int256" },
      { "name": "startedAt", "type": "uint256", "internalType": "uint256" },
      { "name": "updatedAt", "type": "uint256", "internalType": "uint256" },
      { "name": "answeredInRound", "type": "uint80", "internalType": "uint80" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "latestTimestamp",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "updateAnswer",
    "inputs": [
      { "name": "_answer", "type": "int256", "internalType": "int256" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "updateRoundData",
    "inputs": [
      { "name": "_roundId", "type": "uint80", "internalType": "uint80" },
      { "name": "_answer", "type": "int256", "internalType": "int256" },
      { "name": "_timestamp", "type": "uint256", "internalType": "uint256" },
      { "name": "_startedAt", "type": "uint256", "internalType": "uint256" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "version",
    "inputs": [],
    "outputs": [
      { "name": "", "type": "uint256", "internalType": "uint256" }
    ],
    "stateMutability": "view"
  }
]
