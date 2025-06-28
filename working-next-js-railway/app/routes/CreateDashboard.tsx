"use client";

import { useSearchParams } from "next/navigation";
import { Tabs } from "@radix-ui/themes";
import { useCurrentAccount } from "@mysten/dapp-kit";
import VerifyDaoForm from "../components/daos/VerifyDaoForm";
import CreateDaoForm from "../components/daos/CreateDaoForm";
import CreateProposalForm from "../components/daos/CreateProposalForm";

export function CreateDashboard() {
  const account = useCurrentAccount();
  const searchParams = useSearchParams();
  const daoid = searchParams.get("dao") || undefined;

  return (
    <Tabs.Root defaultValue="proposal">
      <Tabs.List>
        <Tabs.Trigger value="proposal" className="cursor-pointer">
          Create Proposal
        </Tabs.Trigger>
        <Tabs.Trigger value="dao" className="cursor-pointer">
          Create DAO
        </Tabs.Trigger>
        <Tabs.Trigger value="verify" className="cursor-pointer">
          Get a DAO Verified
        </Tabs.Trigger>
      </Tabs.List>

      <Tabs.Content value="proposal">
        <CreateProposalForm
          walletAddress={account?.address ?? ""}
          daoIdFromUrl={daoid}
        />
      </Tabs.Content>

      <Tabs.Content value="dao">
        <CreateDaoForm />
      </Tabs.Content>

      <Tabs.Content value="verify">
        <VerifyDaoForm />
      </Tabs.Content>
    </Tabs.Root>
  );
}
