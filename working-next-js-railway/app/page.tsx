export default function HomePage() {
  return (
    <main className="min-h-screen bg-gray-900 text-white p-8">
      <h1 className="text-4xl font-bold mb-4">GovEx Trading Platform</h1>
      <p className="text-lg text-gray-300">
        Welcome to the futarchy-based governance trading platform.
      </p>
      <div className="mt-8 space-y-4">
        <a href="/create" className="block text-blue-400 hover:text-blue-300">
          → Create Dashboard
        </a>
        <a href="/learn" className="block text-blue-400 hover:text-blue-300">
          → Learn
        </a>
      </div>
    </main>
  );
}
