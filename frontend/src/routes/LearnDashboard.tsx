import { Box, Container, Flex, Text, Heading, Card, Grid, Link } from "@radix-ui/themes";
import { ArrowRightIcon } from "@radix-ui/react-icons";
import { NavLink } from "react-router-dom";

export function LearnDashboard() {
  return (
    <Container className="py-8 max-w-4xl mx-auto px-4">
      <Heading size="8" className="text-white mb-6 text-center">
        Learn About <span className="text-blue-400">Govex</span>
      </Heading>

      <Flex direction="column" gap="6">
        <Text as="p" size="4" className="text-gray-100 font-medium text-center mb-2">
          Govex is a distributed decision control system for digitally scarce assets.
        </Text>

        <Card className="p-6 border border-blue-800 bg-gray-900/60 shadow-xl rounded-xl backdrop-blur-sm">
          <Heading size="5" className="text-blue-400 mb-3 flex items-center">
            <Box className="w-2 h-8 bg-blue-500 mr-3 rounded-full"></Box>
            What is Govex?
          </Heading>
          <Text as="p" size="3" className="text-gray-100 leading-relaxed mb-6">
            We believe markets should be used to decide the most important decisions organizations make.
            Markets are the most accurate and efficient information gathering mechanism humanity has invented.
            Govex DAOs are analogous to the board of directors, and the public markets in a single entity.
            An entity with millisecond latency root access. Govex DAOs only execute instructions that the
            markets predict will increase its price. This means that members of Govex DAOs are better
            protected from mismanagement than members of legacy organizations that rely on voting.
          </Text>
          
          <Heading size="5" className="text-blue-400 mb-3 flex items-center mt-6">
            <Box className="w-2 h-8 bg-blue-500 mr-3 rounded-full"></Box>
            How to Get Started
          </Heading>
          <Grid columns={{ initial: "1", sm: "2" }} gap="4" className="mt-3">
            <Box className="text-gray-100">
              <ol className="list-decimal pl-5 space-y-2">
                <li className="pl-2">Connect your Sui wallet</li>
                <li className="pl-2">Create a new Govex DAO or choose an existing one</li>
                <li className="pl-2">Create a proposal for the DAO</li>
              </ol>
            </Box>
            <Box className="text-gray-100">
              <ol className="list-decimal pl-5 space-y-2" start={4}>
                <li className="pl-2">Trade the existing proposal</li>
                <li className="pl-2">Wait for the trading period to finish</li>
                <li className="pl-2">The DAO will execute the instructions</li>
              </ol>
            </Box>
          </Grid>
          <Flex justify="end" mt="4">
            <Link asChild className="text-blue-400 hover:text-blue-300 transition-colors flex items-center gap-1">
              <NavLink to="/">
                Get started now <ArrowRightIcon />
              </NavLink>
            </Link>
          </Flex>
        </Card>
      </Flex>
    </Container>
  );
}

export default LearnDashboard;
