// src/jobHandler.ts
import { ethers } from 'ethers';

interface JobDetails {
    jobId: string;
    cid: string;
    clientAddress: string;
    previousBlockHash: string; // Hash of block.number-1
    providerAddress: string;   // The address of the provider assigned/selected for this job
}

// This will be the URL of our stub provider agent
const STUB_PROVIDER_AGENT_URL = "http://localhost:3001/receive-job"; // Example

export async function handleNewJob(job: JobDetails) {
    console.log(`Processing job ${job.jobId} for provider ${job.providerAddress}`);

    // 1. Calculate the seed
    // seed = keccak256(blockhash(block.number-1) ‖ jobId ‖ providerAddr)
    const seed = ethers.keccak256(
        ethers.solidityPacked(
            ["bytes32", "uint256", "address"],
            [job.previousBlockHash, job.jobId, job.providerAddress]
        )
    );

    console.log(`   Calculated Seed: ${seed}`);
    console.log(`   Input CID: ${job.cid}`);

    // 2. Relay job to stub provider agent (simple HTTP POST)
    try {
        const response = await fetch(STUB_PROVIDER_AGENT_URL, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                jobId: job.jobId,
                cid: job.cid,
                seed: seed,
                // any other data the provider might need
            }),
        });

        if (response.ok) {
            const result = await response.json();
            console.log(`   Job relayed to stub provider. Response:`, result);
        } else {
            console.error(`   Failed to relay job to stub provider. Status: ${response.status}`);
            const errorText = await response.text();
            console.error(`   Error details: ${errorText}`);
        }
    } catch (error) {
        console.error(`   Error relaying job to stub provider:`, error);
    }

    // (Optional for this week, good for future) Add job to Redis queue or database
    // For example, using ioredis:
    // import Redis from 'ioredis';
    // import { REDIS_URL } from './config';
    // const redis = new Redis(REDIS_URL);
    // await redis.set(`job:${job.jobId}:status`, 'relayed_to_provider');
}