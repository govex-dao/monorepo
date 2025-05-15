import { Box, Container, Flex, Link, Text } from "@radix-ui/themes";
import { NavLink } from "react-router-dom";
import { HeaderWithGlowIcon } from "../HeaderWithGlowIcon.tsx";
import { GitHubLogoIcon, DiscordLogoIcon } from "@radix-ui/react-icons";
import { SuiSymbol } from "../icons/SuiSymbol.tsx";

export function Footer() {
  return (
    <Box className="border-t border-gray-800 mt-auto  text-white w-full">
      <Container className="max-w-7xl mx-auto">
        <Flex
          px="6"
          py="8"
          direction={{ initial: "column", md: "row" }}
          justify="between"
          align={{ initial: "start", md: "start" }}
          gap="6"
        >
          <Flex direction="column" gap="3" className="max-w-xs">
            <NavLink to="/">
              <HeaderWithGlowIcon />
            </NavLink>
            <Text size="2" className="text-gray-400 mt-2">
              A distributed decision control system for digitally scarce assets.
            </Text>
          </Flex>

          <Flex gap="8" wrap="wrap" className="mt-6 md:mt-0">
            <Flex direction="column" gap="3">
              <Text weight="bold" size="3" className="text-blue-400 mb-1">
                Platform
              </Text>
              <Link
                asChild
                size="2"
                className="text-gray-300 hover:text-white transition-colors"
              >
                <NavLink to="/">Trade</NavLink>
              </Link>
              <Link
                asChild
                size="2"
                className="text-gray-300 hover:text-white transition-colors"
              >
                <NavLink to="/create">Create</NavLink>
              </Link>
              <Link
                asChild
                size="2"
                className="text-gray-300 hover:text-white transition-colors"
              >
                <NavLink to="/learn">Learn</NavLink>
              </Link>
            </Flex>

            <Flex direction="column" gap="3">
              <Text weight="bold" size="3" className="text-blue-400 mb-1">
                Resources
              </Text>
              <Link
                href="https://docs.sui.io/"
                target="_blank"
                size="2"
                className="text-gray-300 hover:text-white transition-colors flex items-center gap-1"
              >
                <SuiSymbol width={16} height={20} className="inline mr-1" /> Sui
                Docs
              </Link>
              <Link
                href="https://github.com/govex-dao/monorepo"
                target="_blank"
                size="2"
                className="text-gray-300 hover:text-white transition-colors flex items-center gap-1"
              >
                <GitHubLogoIcon className="inline mr-1" /> GitHub
              </Link>
            </Flex>

            <Flex direction="column" gap="3">
              <Text weight="bold" size="3" className="text-blue-400 mb-1">
                Connect
              </Text>
              <Link
                href="https://x.com/govexdotai"
                target="_blank"
                size="2"
                className="text-gray-300 hover:text-white transition-colors flex items-center gap-1"
              >
                <img
                  src="/images/x-logo.png"
                  alt="X logo"
                  className="w-4 h-4 mr-1"
                />{" "}
                govexdotai
              </Link>
              <Link
                href="https://discord.gg/k3sjprgMD4"
                target="_blank"
                size="2"
                className="text-gray-300 hover:text-white transition-colors flex items-center gap-1"
              >
                <DiscordLogoIcon className="inline mr-1" /> Discord
              </Link>
            </Flex>
          </Flex>
        </Flex>
      </Container>
    </Box>
  );
}
