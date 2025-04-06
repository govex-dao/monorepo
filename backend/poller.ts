import { twapPoller } from './poller/twapPoller';

// Start the polling service
setTimeout(() => {
      twapPoller.startPolling();
    }, 5_000); // 30 second delay