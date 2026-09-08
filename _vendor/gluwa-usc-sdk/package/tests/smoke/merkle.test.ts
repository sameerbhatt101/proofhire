import { test, expect } from '@jest/globals';

import { MerkleProofEntry, TransactionMerkleProof, KeccakMerkleTree, ZERO_HASH } from '../../src/proof-provider/merkle';

test('MerkleTree should fail to generate proof for non-existent leaf', async () => {
  const tree = new KeccakMerkleTree([]);

  // The root of an empty tree should be the ZERO_LEAF
  expect(tree.getRoot()).toBe(ZERO_HASH);

  // Attempting to generate a proof for any index should throw an error
  expect(() => tree.getProof(0)).toThrow();
});

test('MerkleTree should generate correct proof with single leaf', async () => {
  const leaves = ['0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'];

  const tree = new KeccakMerkleTree(leaves);

  const expectedRoot = '0x815bde701647c66bafabad0989cccc955bf07110ed03619a85aa13cc4206c531';
  expect(tree.getRoot()).toBe(expectedRoot);

  // Proof for the first (and only) leaf (index 0)
  const proof = tree.getProof(0);

  const expectedProof = new TransactionMerkleProof(expectedRoot, []);
  expect(proof).toEqual(expectedProof);
});

test('MerkleTree should generate correct proof with even number of leaves', async () => {
  const leaves = [
    '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    '0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    '0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
    '0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  ];

  const tree = new KeccakMerkleTree(leaves);

  const expectedRoot = '0x100ee33e3abc39fd1e939278fcfc34fb7a01a9cf5747b108d8b9a5c6ac5a0092';
  expect(tree.getRoot()).toBe(expectedRoot);

  // Proof for the third leaf (index 2)
  const proof = tree.getProof(2);

  const expectedProof = new TransactionMerkleProof(expectedRoot, [
    new MerkleProofEntry('0xd219ac3afe0c22ab430e6bae2cd79be4cb2f51123e63bc789bcc726bc0554f35', false),
    new MerkleProofEntry('0xbd9c165c74372d1127501b0e0b84c7a6c1866e290e1d2f4c2ed51842fa6da48a', true),
  ]);
  expect(proof).toEqual(expectedProof);
});

test('MerkleTree should generate correct proof with odd number of leaves', async () => {
  const leaves = [
    '0xfb52162f25b1ca12398659a03fa143caf99f9257f02777f5b10f9617aed538cb7a02b8a2',
    '0x1dcc4de8645dec75d7aab8b567b6ccd41ad312451b948a7413f0a142fd40d49347',
    '0x608060405234801561000f575f5ffd5b50604051806040016040520600981526020017f4275726e205',
  ];

  const tree = new KeccakMerkleTree(leaves);

  const expectedRoot = '0x89747d056f3e150c85308efd1076947d9009855cf39863d30e7b9651fd9b8244';
  expect(tree.getRoot()).toBe(expectedRoot);

  // Proof for the second leaf (index 1)
  const proof = tree.getProof(1);

  const expectedProof = new TransactionMerkleProof(expectedRoot, [
    new MerkleProofEntry('0xadcb4c6a939c9a5e181b1d5947223253416fb77ed4d8052756ddf657c4a21079', true),
    new MerkleProofEntry('0xa4c1c34e2a24c589628467a97efcba8d0417b9a7941605ff5dc32ed55b3050d1', false),
  ]);
  expect(proof).toEqual(expectedProof);
});

test('MerkleTree should generate correct proof with large number of leaves', async () => {
  const leaves = [
    '0xfb52162f25b1ca12398659a03fa143caf99f9257f02777f5b10f9617aed538cb7a02b8a2',
    '0x1dcc4de8645dec75d7aab8b567b6ccd41ad312451b948a7413f0a142fd40d49347',
    '0x608060405234801561000f575f5ffd5b50604051806040016040520600981526020017f4275726e205',
    '0x1dcc4de8645dec75d7aab8b567b6ccd41ad312451b948a7413f0a142fd40d49347',
    '0xfb52162f25b1ca12398659a03fa143caf99f9257f02777f5b10f9617aed538cb7a02b8a2',
    '0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4cdc86b8f71de3f2a3',
    '0x4e2a2b4e5a8f6d9c3b1a7e8f2d5c6b9a3e7f1c4d8b2a5e9f3c6d1b8a4e7f2c52',
    '0x7b3f8e2a1d4c9b6a5e3f7c2d8b1a9e4f6c3d7b223a8e5f1c9d6b3a7e4f2c8d5b',
    '0x5c8d2e6f9a1b4c7e2f5a8d1b4e7c2a5f8d3b6e9c2a5f8d1b4e7c3a6f9d2b5e81',
    '0xa1b2c3d4e5f6789abcdef0123456789abcdef0123456789abcdef0123456789d',
    '0x1dcc4de8645de335d7aab8b567b6ccd41a1212451b948a7413f0a142fd40d493aa',
    '0x608060405234801561000f575f5ffd5b50604051806040016040520600981526020017f4275726e2061626',
    '0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4cdc86b8f71de3f2a4',
    '0x4e2a2b4e5a8f6d9c3b1a7e8f2d5c6b9a3e7f1c4d8b2a5e9f3c6d1b8a4e7f2c5a',
    '0x7b3f8e2a1d4c9b6a5e3f7c2d8b1a9e4f6c3d7b223a8e5f1c9d6b3a7e4f2c8d5b23',
    '0x5c8d2e6f9a1b4c7e2f5a8d1b4e7c2a5f8d3b6e9c2a5f8d1b4e7c3a6f9d2b5e',
    '0xa1b2c3d4e5f6789abcdef0123456789abcdef0123456789abcdef012345679',
    '0xfb52162f25b1ca12398659a03fa143caf99f9257f02777f5b10f9617aed538cb7a02b8a2',
    '0x1dcc4de8645dec75d7aab8b567b6ccd41ad312451b948a7413f0a142fd40d49347',
    '0x608060405234801561000f575f5ffd5b50604051806040016040520600981526020017f4275726e205',
    '0x1dcc4de8645dec75d7aab8b567b6ccd41ad312451b948a7413f0a142fd40d49347',
    '0xfb52162f25b1ca12398659a03fa143caf99f9257f02777f5b10f9617aed538cb7a02b8a2',
    '0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4cdc86b8f71de3f2a3',
    '0x4e2a2b4e5a8f6d9c3b1a7e8f2d5c6b9a3e7f1c4d8b2a5e9f3c6d1b8a4e7f2c52',
    '0x7b3f8e2a1d4c9b6a5e3f7c2d8b1a9e4f6c3d7b223a8e5f1c9d6b3a7e4f2c8d5b',
    '0x5c8d2e6f9a1b4c7e2f5a8d1b4e7c2a5f8d3b6e9c2a5f8d1b4e7c3a6f9d2b5e81',
    '0xa1b2c3d4e5f6789abcdef0123456789abcdef0123456789abcdef0123456789d',
    '0x1dcc4de8645de335d7aab8b567b6ccd41a1212451b948a7413f0a142fd40d493aa',
    '0x608060405234801561000f575f5ffd5b50604051806040016040520600981526020017f4275726e2061626',
    '0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4cdc86b8f71de3f2a4',
    '0x4e2a2b4e5a8f6d9c3b1a7e8f2d5c6b9a3e7f1c4d8b2a5e9f3c6d1b8a4e7f2c5a',
    '0x7b3f8e2a1d4c9b6a5e3f7c2d8b1a9e4f6c3d7b223a8e5f1c9d6b3a7e4f2c8d5b23',
    '0x5c8d2e6f9a1b4c7e2f5a8d1b4e7c2a5f8d3b6e9c2a5f8d1b4e7c3a6f9d2b5e',
    '0xa1b2c3d4e5f6789abcdef0123456789abcdef0123456789abcdef012345679',
  ];

  const tree = new KeccakMerkleTree(leaves);

  const expectedRoot = '0xa04659d4930f4b5a9709a1a3591cf3c62e13015d8b94b723308c33649e8fab3c';
  expect(tree.getRoot()).toBe(expectedRoot);

  // Proof for the tenth leaf (index 9)
  const proof = tree.getProof(9);

  const expectedProof = new TransactionMerkleProof(expectedRoot, [
    new MerkleProofEntry('0xc21fb8041448aa652f1b837d01aa9c8f083aba7a8207637415a8d78e4af4fcb5', true),
    new MerkleProofEntry('0x4a898fd147b3daa99c2145216054f6986cadc2b570706830a4941998426724c5', false),
    new MerkleProofEntry('0xcd7e3a035ec0e7953d8688ec75cb4eec3c2b55aea058effceb61e2c6c5809107', false),
    new MerkleProofEntry('0x61d42ce59be52e0f01ff6fbf175cf022e455e741042eddb4266cbb032bd8a937', true),
    new MerkleProofEntry('0x01a1b9dc0e13ab05b2aecc6fa2d287d0c02d580f30c71d2f9d337d6b37520e79', false),
    new MerkleProofEntry('0x7c6a8d4c98ff02021de6393b0ccc11aaee8bf3fe672aa64b3b71dbbf92dd0995', false),
  ]);
  expect(proof).toEqual(expectedProof);
});
