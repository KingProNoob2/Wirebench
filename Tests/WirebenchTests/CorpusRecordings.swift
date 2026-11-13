/// Pin recordings (see `PinChain`) taken from the Swift `SimulationEngine` before it was deleted, while it and
/// the C++ core agreed pin for pin on every project here.
///
/// `SSemafor(1).pcc` was re-baselined when the engine's pin-0 gate was corrected: the old engine skipped any block
/// whose first input read 0, but the help gives `Int2Bits` no `En` — its first pin is X — so an X of 0 must run and
/// drive every bit low rather than hold the previous bits. Each run is 200 every-tick steps at the fixed test
/// instant; the four values are the chain after steps 49, 99, 149 and 199.
///
/// Keyed by fixture name or `.pcc` file name. A project added to the corpus later has no recording, and the
/// comparison says so rather than passing silently.
enum CorpusRecordings {
    static let chains: [String: [UInt64]] = [
        "nested macros": [0xd3fd5abe86f6e3c1, 0x74362927c819ddbd, 0x9a32f5b4717b28d9, 0xf808f10bfee5bd55],
        "two calls": [0x4195b71e14b7884d, 0x671f8d99c7e2d2b5, 0x6e331fb0e5cd871d, 0xee7492dc41a53985],
        "pulseIntoNot": [0x4b38c535ec051d02, 0xbb6aa38a5703bfb1, 0xd4dbfa1b9d878c7e, 0xad7712fbf98e9375],
        "macro bridge": [0x8a1d1f3a33c043d0, 0x4b75d1bcad751c7c, 0xc1fd30dbc02d8f8, 0x809059f2245f2bc4],
        "AHOJ - JEDNOSEGMENT.pcc": [0x29ce60efbd87d65d, 0x94d338b9114f8695, 0x842c3838fe9f28cd, 0x506ed2c7f453f705],
        "AHOJ 1.pcc": [0xaa44258fb177c225, 0x84c36715cf226925, 0x1da28129fe69d825, 0x63389e2d56d7cf25],
        "LEDky.pcc": [0x24c41bdd77696423, 0x2b72805fc63e4f23, 0xbfdcc0c092577a23, 0xd8315ed8ade4e523],
        "RS a RST.pcc": [0x4edfa073af9f0e85, 0xd342e9198244b065, 0xf28c29159e08bfc5, 0x67a916a4c7f6f5a5],
        "RST.pcc": [0x28de5c67911cbb3d, 0xb3ea868c0a90ac95, 0x429e71cd22d8c7ad, 0xccbf6138b6c4fc05],
        "SSemafor(1).pcc": [9725628583511751615, 1279638271165106778, 6145921008825782999, 17495457952356736069],
        "autoplexer.pcc": [0x28de63be65b595e5, 0xbbae9e895d2c43a5, 0xabd7cb06fb04e265, 0x9abb74ce73f7dc25],
        "binarni odcitacka.pcc": [0xdf47d429d6bcb485, 0x3c74e329596666e5, 0x7a433a40a4fd0f45, 0x63567ddb2d797ea5],
        "binarni scitacka.pcc": [0xda5f0e5d7b338bab, 0x51d4713c89230af1, 0xb8e2b1ed23278bf7, 0xa7765af180b50b8d],
        "com do plc.pcc": [0xceb4204f02e4bcf9, 0xbc79d8dafbd096ad, 0x8972af8b76394c21, 0x592f752f5accd135],
        "dvousegment.pcc": [0x1414e9c0041453af, 0x7fe6d878c4705f8d, 0x53b03b288e57e457, 0x5bf2f64305635395],
        "ehhhhhh zelznice.pcc": [0xc43352e75794509c, 0xa1df2fb85c4c5c76, 0x44e4f6ac1a57af18, 0x211bf01c665b6772],
        "had+1block.pcc": [0xa8a4f55bd7f727f5, 0x55441a65f84b4085, 0x7798bf862fabd1d5, 0xaa1a3ee7e404d365],
        "had.pcc": [0xb90b3db6637b1465, 0xd16112ccd336fea5, 0x7bb98d26a6e5afe5, 0xa93623d3a9d75a25],
        "had_dvousegment.pcc": [0x37226b3309b47a77, 0x83cd021c215de99, 0xb49621960872af2b, 0x7eda3ab7dcaa996d],
        "had_osmicka.pcc": [0x246a91373f77f53d, 0x1c3c2e2ec8ddb595, 0x56965505975a6ded, 0x19208d90930f8485],
        "jk_master_slave.pcc": [0x2e1a256371c1e897, 0xf53306d3da5d6b11, 0x624d2c4737b3dd83, 0xa295cfa39a115bcd],
        "konvertor.pcc": [0x3946901bb1a0cb1d, 0xed738685c79d37f5, 0x610186e6be4682ed, 0x859f47fa68a1fa45],
        "kostička.pcc": [0x32b3b8fa28352339, 0xe5e6f22629e4870d, 0xc6ffe80ae8b862c1, 0x67dcb08f81f9a015],
        "kostička_druhá.pcc": [0x2e4d574594cbd8b1, 0xe251981bcb3a4dd, 0x608adeec32cd4609, 0xce0a4b426bb508d5],
        "minutka.pcc": [0x5c4e3c13012ba021, 0xf60e21931d01164d, 0xa26d2cfebe99fb49, 0x110b1caee53d17d5],
        "multiplexer.pcc": [0x6899fb217a80bc41, 0x2a532632c2d0874d, 0xe7f74c92217be669, 0x3d5c35256ff68b95],
        "ruleta_kostka_had.pcc": [0x282a65b445ff00bd, 0x3702b07478095cb7, 0x22e2da4ac87cb021, 0xe7b95ce519ae4ab],
        "rulkoshaddirigo.pcc": [0xcd3052fda3654c9, 0xb72640a8af89ee7b, 0x63b6916cb03458c9, 0x60448fab7792f27b],
    ]
}
