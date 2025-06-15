import React, { useState } from "react";
import { Transaction } from "@mysten/sui/transactions";
import { InfoCircledIcon, ClipboardIcon } from "@radix-ui/react-icons";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { useSuiTransaction } from "@/hooks/useSuiTransaction";
import toast from "react-hot-toast";
import DaoSearchInput from "./DaoSearchInput";
import { CONSTANTS } from "../../constants";
import { VerificationHistory } from "./VerificationHistory";
import { VerifiedIcon } from "../icons/VerifiedIcon";
import UnverifiedIcon from "../icons/UnverifiedIcon";

interface DaoData {
  dao_id: string;
  minAssetAmount: string;
  minStableAmount: string;
  assetType: string;
  stableType: string;
  dao_name: string;
  dao_icon: string;
  icon_url: string;
  icon_cache_path: string | null;
  verification?: {
    verified: boolean;
  };
}

interface FormData {
  daoId: string;
  attestationUrl: string;
}

const tooltips = {
  daoId: "The DAO name or ID that you want to get verified",
  attestationUrl:
    "Tweet @govexdotai with the onchain ID of the DAO you wish to formally affiliate with your organization.",
};

const truncateAddress = (address: string) => {
  if (address.length <= 20) return address;
  return `${address.slice(0, 10)}...${address.slice(-10)}`;
};

const VerifyDaoForm = () => {
  const [formData, setFormData] = useState<FormData>({
    daoId: "",
    attestationUrl: "",
  });

  const [selectedDao, setSelectedDao] = useState<DaoData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const currentAccount = useCurrentAccount();
  const { executeTransaction, isLoading } = useSuiTransaction();

  const handleInputChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const { name, value } = e.target;
    setFormData((prev) => ({
      ...prev,
      [name]: value,
    }));
  };

  const handleDaoSelect = (daoData: DaoData | null) => {
    setSelectedDao(daoData);
    setFormData((prev) => ({
      ...prev,
      daoId: daoData?.dao_id || "",
    }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    if (!currentAccount) {
      toast.error("Please connect your wallet before verifying a DAO.");
      return;
    }

    try {
      if (!formData.daoId) {
        throw new Error("No DAO selected");
      }

      if (!formData.attestationUrl) {
        throw new Error("Tweet URL is required");
      }

      const tx = new Transaction();
      const isMainnet = CONSTANTS.network === "mainnet";
      const gasBudget = isMainnet ? 500_000_000 : 500_000_000;
      const splitAmount = isMainnet ? 10_000_000_000 : 10_000;
      tx.setGasBudget(gasBudget);
      const [splitCoin] = tx.splitCoins(tx.gas, [tx.pure.u64(splitAmount)]);

      tx.moveCall({
        target: `${CONSTANTS.futarchyPackage}::factory::request_verification`,
        arguments: [
          tx.object(CONSTANTS.futarchyPaymentManagerId),
          splitCoin,
          tx.object(formData.daoId),
          tx.pure.string(formData.attestationUrl),
          tx.object("0x6"),
        ],
      });

      await executeTransaction(
        tx,
        {
          onSuccess: () => {
            setFormData({
              daoId: "",
              attestationUrl: "",
            });
            setSelectedDao(null);
          },
          onError: (error) => {
            setError(error.message);
          },
        },
        {
          loadingMessage: "Requesting DAO verification...",
          successMessage: "Verification request submitted successfully!",
          errorMessage: (error) => {
            if (error.message?.includes("Rejected from user")) {
              return "Transaction cancelled by user";
            } else if (error.message?.includes("Insufficient gas")) {
              return "Insufficient SUI for gas fees";
            }
            return `Failed to request verification: ${error.message}`;
          },
        }
      );
    } catch (err) {
      // Handle pre-transaction errors (validation, etc.)
      const errorMessage =
        err instanceof Error ? err.message : "Failed to request verification";
      setError(errorMessage);
      toast.error(errorMessage);
    }
  };

  return (
    <div className="p-6 max-w-2xl mx-auto">
      <form onSubmit={handleSubmit} className="space-y-4">
        <DaoSearchInput
          value={formData.daoId}
          onChange={handleInputChange}
          onDaoSelect={handleDaoSelect}
          tooltip={tooltips.daoId}
        />

        {selectedDao && (
          <div className="bg-gray-900 rounded-lg p-3">
            <div className="flex items-center space-x-3 mb-2">
              <div className="w-10 h-10 flex-shrink-0">
                <img
                  src={selectedDao.dao_icon || "/placeholder-dao.png"}
                  alt={selectedDao.dao_name}
                  className="w-full h-full rounded-full object-cover"
                  onError={(e) => {
                    e.currentTarget.src = "/placeholder-dao.png";
                  }}
                />
              </div>
              <div className="flex-grow min-w-0">
                <div className="font-medium text-gray-200 truncate flex items-center">
                  {selectedDao.dao_name}
                  {selectedDao.verification?.verified ? (
                    <VerifiedIcon className="ml-1 flex-shrink-0" />
                  ) : (
                    <UnverifiedIcon className="ml-1 flex-shrink-0" />
                  )}
                </div>
                <div className="font-mono text-sm text-gray-400 flex items-center space-x-2">
                  <span className="truncate">
                    {truncateAddress(formData.daoId)}
                  </span>
                  <button
                    type="button"
                    onClick={(e) => {
                      e.preventDefault();
                      navigator.clipboard.writeText(
                        `@govexdotai here is the ID for our official DAO: ${formData.daoId}. We are excited to try futarchy on Sui 🚀`,
                      );
                      toast.success("DAO ID copied to clipboard");
                    }}
                    className="hover:text-gray-200 transition-colors"
                  >
                    <ClipboardIcon className="w-5 h-5" />
                  </button>
                </div>
              </div>
            </div>
          </div>
        )}

        <div className="space-y-2">
          <div className="flex items-center space-x-2">
            <label className="block text-sm font-medium">
              Give us a tweet from the project's official Twitter account with
              the DAO ID.
            </label>
            <div className="relative group">
              <InfoCircledIcon className="w-4 h-4 text-gray-400 hover:text-gray-600 cursor-help" />
              <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
                {tooltips.attestationUrl}
              </div>
            </div>
          </div>
          <input
            type="text"
            name="attestationUrl"
            value={formData.attestationUrl}
            onChange={handleInputChange}
            className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500"
            placeholder="Enter tweet URL"
            required
          />
        </div>

        <div className=" rounded-lg p-4 space-y-2">
          <h3 className="text-lg font-medium text-gray-200 mb-3">
            Verification Requirements:
          </h3>
          <ul className="list-disc pl-5 space-y-2 text-gray-300">
            <li>The DAO's metadata is unique.</li>
            <li>
              The attestation tweet is from the organization's official Twitter
              account.
            </li>
            <li>The Twitter account has a verified tick.</li>
            <li>Please wait for up to one week to get your DAO verified.</li>
          </ul>
        </div>

        {error && <div className="text-red-500 text-sm">{error}</div>}

        <button
          type="submit"
          disabled={isLoading}
          className="w-full bg-blue-500 text-white py-2 px-4 rounded hover:bg-blue-600 disabled:bg-blue-300 disabled:cursor-not-allowed"
        >
          {isLoading ? "Verifying..." : "Get DAO Verified"}
        </button>
      </form>
      <VerificationHistory
        daoId={formData.daoId}
        daoName={selectedDao?.dao_name}
        isSelected={Boolean(selectedDao)}
      />
    </div>
  );
};

export default VerifyDaoForm;
