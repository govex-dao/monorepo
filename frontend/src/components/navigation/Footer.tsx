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

export function MinimalFooter() {
  return (
    <footer className="bg-gradient-to-b from-gray-950/30 to-black/30 border-t border-gray-800 py-2 px-4 mt-auto w-full">
      <Container className="mx-auto px-6">
        <Flex
          align="center"
          justify={{ initial: "center", sm: "between" }}
          gap="2"
          className="text-xs"
        >
          <Flex align="center" gap="2" className="hidden sm:flex text-gray-400">
            <Text size="1" className="flex items-center gap-1.5 font-medium">
              <span className="">Govex.ai</span>
              <span className="text-gray-500 text-xs opacity-80">•</span>
              <span className="text-gray-400 opacity-80">
                {new Date().getFullYear()}
              </span>
            </Text>
          </Flex>

          <Flex gap="6" justify="center" align="center" className="">
            <Flex gap="3" className="hidden sm:flex flex-wrap justify-center">
              <Link
                asChild
                size="1"
                className="text-gray-500 hover:text-white transition-colors"
              >
                <NavLink to="/">Trade</NavLink>
              </Link>
              <span className="text-gray-500 flex items-center">•</span>
              <Link
                asChild
                size="1"
                className="text-gray-500 hover:text-white transition-colors"
              >
                <NavLink to="/create">Create</NavLink>
              </Link>
            </Flex>

            <div className="hidden sm:block h-4 w-[1px] bg-gray-500/50"></div>

            <Flex gap="3" justify="center">
              <Link
                href="https://docs.sui.io/"
                target="_blank"
                className="text-gray-400 hover:text-white transition-colors"
              >
                <SuiSymbol width={12} height={14} />
              </Link>
              <Link
                href="https://github.com/govex-dao/monorepo"
                target="_blank"
                className="text-gray-400 hover:text-white transition-colors"
              >
                <GitHubLogoIcon width={14} height={14} />
              </Link>
              <Link
                href="https://x.com/govexdotai"
                target="_blank"
                className="text-gray-400 hover:text-white transition-colors"
              >
                <img
                  src="/images/x-logo.png"
                  alt="X logo"
                  className="w-3.5 h-3.5"
                />
              </Link>
              <Link
                href="https://discord.gg/k3sjprgMD4"
                target="_blank"
                className="text-gray-400 hover:text-white transition-colors"
              >
                <DiscordLogoIcon width={14} height={14} />
              </Link>
            </Flex>
          </Flex>
        </Flex>
      </Container>
    </footer>
  );
}
