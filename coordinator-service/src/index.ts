// coordinator-service/src/index.ts
import { startListening } from './blockchainListener';

function main() {
    console.log("Starting Coordinator Service...");
    startListening();
    // You can add other initializations here (e.g., API for status checks)
}

main();