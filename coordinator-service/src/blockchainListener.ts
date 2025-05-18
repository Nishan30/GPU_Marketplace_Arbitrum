// src/blockchainListener.ts
import { ethers } from 'ethers';
import { RPC_URL, JOB_MANAGER_ADDRESS } from './config';
import JobManagerABI from './abis/JobManager.json'
import { handleNewJob } from './jobHandler';

export function startListening() {
    const provider = new ethers.JsonRpcProvider(RPC_URL);
    const jobManager = new ethers.Contract(JOB_MANAGER_ADDRESS, JobManagerABI.abi, provider);

    console.log(`Listening for JobCreated events on JobManager at ${JOB_MANAGER_ADDRESS}...`);

    jobManager.on("JobCreated", async (jobId, client, cid, maxGas, deadline, event) => {
        console.log("🎉 New JobCreated Event Received!");
        console.log(`   Job ID: ${jobId.toString()}`);
        console.log(`   Client: ${client}`);
        console.log(`   CID: ${cid}`);
        console.log(`   Max Gas: ${maxGas.toString()}`);
        console.log(`   Deadline: ${new Date(Number(deadline) * 1000)}`);

        const block = await provider.getBlock(event.log.blockNumber);
        if (!block) {
            console.error(`Could not fetch block ${event.log.blockNumber}`);
            return;
        }
        // block.number is the current block, we need block.number - 1 for the seed
        const previousBlock = await provider.getBlock(block.number - 1);
        if (!previousBlock) {
            console.error(`Could not fetch previous block ${block.number - 1}`);
            // Handle this case: maybe use current blockhash, or retry, or log error
            // For simplicity now, we might skip or use current block's hash as a fallback
            // but ideally, you'd want a robust way to get blockhash(block.number-1)
            return;
        }


        // Pass relevant info to the job handler
        // For now, let's assume a single stub provider for simplicity
        // In a real system, you'd get this from ProviderRegistry or an internal list
        const stubProviderAddress = "0x0000000000000000000000000000000000000001"; // Example stub

        if (!previousBlock.hash) {
            console.error('Previous block hash is null');
            return;
        }

        handleNewJob({
            jobId: jobId.toString(),
            cid: cid,
            clientAddress: client,
            previousBlockHash: previousBlock.hash, // blockhash(block.number-1)
            providerAddress: stubProviderAddress // For seed calculation
        });
    });

    jobManager.on("error", (error) => {
        console.error("Error listening to JobManager events:", error);
        // Implement reconnection logic or error handling
    });
}