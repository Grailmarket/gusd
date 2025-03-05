import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { expect } from 'chai'
import { Contract, ContractFactory } from 'ethers'
import { deployments, ethers } from 'hardhat'

import { Options } from '@layerzerolabs/lz-v2-utilities'

describe('GrailDollar Test', function () {
    // Constant representing a mock Endpoint ID for testing purposes
    const eidA = 1
    const eidB = 2
    // Declaration of variables to be used in the test suite
    let GrailDollar: ContractFactory
    let EndpointV2Mock: ContractFactory
    let ERC20Mock: ContractFactory
    let ownerA: SignerWithAddress
    let ownerB: SignerWithAddress
    let minterA: SignerWithAddress
    let minterB: SignerWithAddress
    let endpointOwner: SignerWithAddress
    let aGUSD: Contract
    let bGUSD: Contract
    let USDC: Contract
    let USDT: Contract
    let mockEndpointV2A: Contract
    let mockEndpointV2B: Contract

    // Before hook for setup that runs once before all tests in the block
    before(async function () {
        // Contract factory for our tested contract
        //
        // We are using a derived contract that exposes a mint() function for testing purposes
        GrailDollar = await ethers.getContractFactory('GrailDollarMock')

        // Fetching the first three signers (accounts) from Hardhat's local Ethereum network
        const signers = await ethers.getSigners()

        ;[ownerA, ownerB, minterA, minterB, endpointOwner] = signers

        // The EndpointV2Mock contract comes from @layerzerolabs/test-devtools-evm-hardhat package
        // and its artifacts are connected as external artifacts to this project
        //
        // Unfortunately, hardhat itself does not yet provide a way of connecting external artifacts,
        // so we rely on hardhat-deploy to create a ContractFactory for EndpointV2Mock
        //
        // See https://github.com/NomicFoundation/hardhat/issues/1040
        const EndpointV2MockArtifact = await deployments.getArtifact('EndpointV2Mock')
        EndpointV2Mock = new ContractFactory(EndpointV2MockArtifact.abi, EndpointV2MockArtifact.bytecode, endpointOwner)

        const ERC20MockArtifact = await deployments.getArtifact('ERC20Mock')
        ERC20Mock = new ContractFactory(ERC20MockArtifact.abi, ERC20MockArtifact.bytecode, endpointOwner)
    })

    // beforeEach hook for setup that runs before each test in the block
    beforeEach(async function () {
        // Deploying a mock LZEndpoint with the given Endpoint ID
        mockEndpointV2A = await EndpointV2Mock.deploy(eidA)
        mockEndpointV2B = await EndpointV2Mock.deploy(eidB)
        USDC = await ERC20Mock.deploy('USDC', 'USDC', 6)
        USDT = await ERC20Mock.deploy('Tether', 'USDT', 18)

        // Deploying two instances of MyOFT contract with different identifiers and linking them to the mock LZEndpoint
        aGUSD = await GrailDollar.deploy(USDC.address, minterA.address, mockEndpointV2A.address, ownerA.address)
        bGUSD = await GrailDollar.deploy(USDT.address, minterB, mockEndpointV2B.address, ownerB.address)

        // Setting destination endpoints in the LZEndpoint mock for each MyOFT instance
        await mockEndpointV2A.setDestLzEndpoint(bGUSD.address, mockEndpointV2B.address)
        await mockEndpointV2B.setDestLzEndpoint(aGUSD.address, mockEndpointV2A.address)

        // Setting each MyOFT instance as a peer of the other in the mock LZEndpoint
        await aGUSD.connect(ownerA).setPeer(eidB, ethers.utils.zeroPad(bGUSD.address, 32))
        await bGUSD.connect(ownerB).setPeer(eidA, ethers.utils.zeroPad(aGUSD.address, 32))
    })

    // A test case to verify token transfer functionality
    it('should send a token from A address to B address via each OFT', async function () {
        // Minting an initial amount of tokens to ownerA's address in the myOFTA contract
        const initialAmount = ethers.utils.parseUnits('100', 6)
        await bGUSD.mint(ownerA.address, initialAmount)

        // Defining the amount of tokens to send and constructing the parameters for the send operation
        const tokensToSend = ethers.utils.parseUnits('1', 6)

        // Defining extra message execution options for the send operation
        const options = Options.newOptions().addExecutorLzReceiveOption(200000, 0).toHex().toString()

        const sendParam = [
            eidB,
            ethers.utils.zeroPad(ownerB.address, 32),
            tokensToSend,
            tokensToSend,
            options,
            '0x',
            '0x',
        ]

        // Fetching the native fee for the token send operation
        const [nativeFee] = await aGUSD.quoteSend(sendParam, false)

        // Executing the send operation from myOFTA contract
        await aGUSD.send(sendParam, [nativeFee, 0], ownerA.address, { value: nativeFee })

        // Fetching the final token balances of ownerA and ownerB
        const finalBalanceA = await aGUSD.balanceOf(ownerA.address)
        const finalBalanceB = await bGUSD.balanceOf(ownerB.address)

        // Asserting that the final balances are as expected after the send operation
        expect(finalBalanceA).eql(initialAmount.sub(tokensToSend))
        expect(finalBalanceB).eql(tokensToSend)
    })
})
