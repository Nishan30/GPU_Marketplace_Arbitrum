// src/config.ts
import dotenv from 'dotenv';
dotenv.config();

export const RPC_URL = process.env.RPC_URL!;
export const JOB_MANAGER_ADDRESS = process.env.JOB_MANAGER_ADDRESS!;
// export const REDIS_URL = process.env.REDIS_URL!; // Uncomment if using Redis

if (!RPC_URL || !JOB_MANAGER_ADDRESS) {
    console.error("Missing environment variables: RPC_URL or JOB_MANAGER_ADDRESS");
    process.exit(1);
}