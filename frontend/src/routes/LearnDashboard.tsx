import { useState } from "react";
import { Tabs, Text, Box } from "@radix-ui/themes";
import { MintTestnetCoins } from "../components/learn/MintTestnetCoins";

export function LearnDashboard() {
  const tabs = [
    {
      name: "Documentation",

      component: () => (
        <Box className="p-4">
          <Text size="5" weight="bold" className="mb-4 text-gray-400">
            In One Sentence:
          </Text>
          <Text as="p" className="mb-3">
            Govex is a distributed decision control system for digitally scarce
            assets.
          </Text>
          <Text size="5" weight="bold" className="mb-4 text-gray-400">
            In One Paragraph:
          </Text>
          <Text as="p" className="mb-3">
            We believe markets should be used to decide the most important
            decisions organizations make. Markets are the most accurate and
            efficient information gathering mechanism humanity has invented.
            Govex DAOs are analogous to the board of directors, and the public
            markets in a single entity. An entity with millisecond latency root
            access. Govex DAOs only execute instructions that the markets
            predict will increase its price. This means that members of Govex
            DAOs are better protected from mismanagement than members of legacy
            organizations that rely on voting.
          </Text>
          <Text size="5" weight="bold" className="mb-4 text-gray-400">
            How to Get Started:
          </Text>
          <Text as="p" className="mb-3">
            <li>1) Connect your Sui wallet.</li>
            <li>2) Create a new Govex DAO or choose an existing one.</li>
            <li>
              3) Create a proposal for the DAO, e.g., 'Rent an office in the UAE
              for the DAO'.
            </li>
            <li>4) Trade the existing proposal.</li>
            <li>5) Wait for the trading period to finish.</li>
            <li>
              6) The DAO will execute the instructions (currently Govex DAOs can
              only advise not execute).
            </li>
          </Text>
        </Box>
      ),
    },
    {
      name: "Tutorials",
      component: () => (
        <Box className="p-4">
          <Text size="5" weight="bold" className="mb-4 text-gray-400">
            Get Started with Test Coins
          </Text>
          <Text as="p" className="mb-4">
            Click below to mint testnet coins that can be used to try out Govex:
          </Text>
          <MintTestnetCoins />
        </Box>
      ),
    },
    {
      name: "Social",
      component: () => (
        <Box className="p-4">
          <Text size="5" weight="bold" className="mb-4"></Text>
          <a
            href="https://x.com/govexdotai"
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center text-[20px] font-bold transition-opacity duration-200 hover:opacity-60"
          >
            <img
              src="/images/x-logo.png"
              alt="X logo"
              className="w-5 h-5 mr-1"
            />
            <span className="-translate-y-[1px]">@govexdotai</span>
          </a>
        </Box>
      ),
    },
  ];

  const [tab, setTab] = useState(tabs[0].name);

  return (
    <Tabs.Root value={tab} onValueChange={setTab}>
      <Tabs.List>
        {tabs.map((tab, index) => (
          <Tabs.Trigger key={index} value={tab.name} className="cursor-pointer">
            {tab.name}
          </Tabs.Trigger>
        ))}
      </Tabs.List>
      {tabs.map((tab, index) => (
        <Tabs.Content key={index} value={tab.name}>
          {tab.component()}
        </Tabs.Content>
      ))}
    </Tabs.Root>
  );
}

export default LearnDashboard;
