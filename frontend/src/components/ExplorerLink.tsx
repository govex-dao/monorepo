// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { useSuiClientContext } from "@mysten/dapp-kit";
import { formatAddress } from "@mysten/sui/utils";
import { CheckIcon, CopyIcon } from "@radix-ui/react-icons";
import { useState } from "react";
import toast from "react-hot-toast";

/**
 * A re-usable component for explorer links that offers
 * a copy to clipboard functionality.
 */
export type ExplorerLinkType =
  | "object"
  | "address" // Addresses are technically objects, but SuiScan supports /address/ path
  | "transaction"
  | "package"
  | "coin" // This usually refers to a coin *type*, e.g., 0x2::sui::SUI
  | "validator";
// Add more types as needed, e.g., "checkpoint", "epoch"

interface ExplorerLinkProps {
  id: string;
  type: ExplorerLinkType;
}

/**
 * A re-usable component for explorer links that offers
 * a copy to clipboard functionality.
 * It uses a switch statement to construct the correct URL based on the entity type.
 */
export function ExplorerLink({ id, type }: ExplorerLinkProps) {
  const [copied, setCopied] = useState(false);
  const { network } = useSuiClientContext();

  let pathSegment = "";

  // The base URL structure is: https://suiscan.xyz/[NETWORK]/[TYPE]/[ID]
  // We only need to determine the [TYPE] part based on the prop.
  switch (type) {
    case "address":
      pathSegment = `address/${id}`;
      // Note: SuiScan often redirects /address/ to /object/ for actual address IDs
      break;
    case "object":
      pathSegment = `object/${id}/fields`;
      break;
    case "transaction":
      pathSegment = `tx/${id}`; // SuiScan uses 'tx' for transactions
      break;
    case "package":
      pathSegment = `package/${id}`;
      break;
    case "coin":
      pathSegment = `coin/0x${id}`;
      break;
    case "validator":
      pathSegment = `validator/${id}`;
      break;
    // Add more cases for other types as needed
    // e.g., case "checkpoint": pathSegment = `checkpoint/${id}`; break;
    default:
      // Fallback or error handling for unknown types
      // For robustness, you might want to default to 'object' or log an error
      console.warn(
        `ExplorerLink: Unknown type "${type}" provided for ID "${id}". Defaulting to object path.`,
      );
      pathSegment = `object/${id}`; // A sensible fallback
      break;
  }

  const link = `https://suiscan.xyz/${network}/${pathSegment}`;

  const copy = () => {
    navigator.clipboard.writeText(id);
    setCopied(true);
    setTimeout(() => {
      setCopied(false);
    }, 2000);
    toast.success("Copied to clipboard!");
  };

  return (
    <span className="flex items-center gap-3">
      {copied ? (
        <CheckIcon />
      ) : (
        <CopyIcon
          height={12}
          width={12}
          className="cursor-pointer"
          onClick={copy}
        />
      )}

      <a href={link} target="_blank" rel="noreferrer">
        {/* formatAddress works well for most IDs (addresses, object IDs)
            For transaction digests, it will also shorten them, which is usually fine. */}
        {formatAddress(id || "")}
      </a>
    </span>
  );
}
