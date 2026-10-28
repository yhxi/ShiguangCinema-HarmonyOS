import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';

/** Passwords are stored by the system asset service, never in preferences. */
export class Credentials {
  private static alias(serverUrl: string): Uint8Array {
    return new util.TextEncoder().encodeInto(`shiguang:${serverUrl}`);
  }

  static async save(serverUrl: string, password: string): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, Credentials.alias(serverUrl));
    attributes.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(password));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
  }

  static async load(serverUrl: string): Promise<string> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, Credentials.alias(serverUrl));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    const result = await asset.query(query);
    if (result.length === 0) { return ''; }
    const secret = result[0].get(asset.Tag.SECRET);
    if (!(secret instanceof Uint8Array)) { return ''; }
    return new util.TextDecoder('utf-8').decodeWithStream(secret);
  }
}
