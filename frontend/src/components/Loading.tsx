// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import LoadingIcon from "./icons/LoadingIcon";

/**
 * A loading spinner that can be re-used across the app.
 */
export function Loading() {
  return (
    <div role="status" className="text-center">
      <LoadingIcon className="w-8 h-8 text-gray-200 animate-spin fill-gray-900 mx-auto my-3" />
      <span className="sr-only">Loading...</span>
    </div>
  );
}
