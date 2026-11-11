import { promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { Device } from '../protocol/Dto';
import { LanShareApp } from '../app/LanShareApp';
import { SendController, OutgoingFile, OutgoingFileStates, SendResult } from '../send/SendController';
import { ReceiveController } from '../receive/ReceiveController';
import { ReceiveSnapshot, ReceivePhases, IncomingFile } from '../receive/ReceiveModels';
import { AppContext } from '../common/AppContext';

const RECEIVE_TAB_INDEX: number = 2;

@Entry
@Component
struct Index {
  @StorageLink('lanshare_devices') devices: Device[] = [];
  @StorageLink('lanshare_receive_state') @Watch('onReceiveState') receiveState: ReceiveSnapshot =
    ReceiveSnapshot.idle();
  @StorageProp('lanshare_server_port') @Watch('onPortPublished') serverPort: number = 0;
  @StorageProp('lanshare_alias') @Watch('onAliasPublished') storedAlias: string = '';
  @StorageProp('lanshare_fingerprint') fingerprint: string = '';
  @StorageProp('lanshare_protocol') protocol: string = '';

  @State sendFiles: OutgoingFile[] = [];
  @State sending: boolean = false;
  @State refreshing: boolean = false;
  @State targetPin: string = '';
  @State aliasDraft: string = '';
  @State portDraft: string = '';
  @State pinDraft: string = '';
  @State textDraft: string = '';
  @State showTextEditor: boolean = false;

  private sendController: SendController = SendController.getInstance();
  private tabsController: TabsController = new TabsController();
  private lastReceivePhase: string = ReceivePhases.IDLE;

  aboutToAppear(): void {
    this.sendController.setChangeListener(() => {
      this.sendFiles = this.sendController.getFiles().slice(0);
    });
    // Bootstrap may already have published these before the page loaded.
    const port = AppStorage.get<number>('lanshare_server_port');
    if (port !== undefined && port > 0 && this.portDraft === '') {
      this.portDraft = `${port}`;
    }
    const alias = AppStorage.get<string>('lanshare_alias');
    if (alias !== undefined && this.aliasDraft === '') {
      this.aliasDraft = alias;
      this.loadSettingDrafts();
    }
  }

  /** Bring the Receive tab forward when a request or text message arrives. */
  onReceiveState(): void {
    const state = this.receiveState;
    const phase = state.phase;
    // A fresh message snapshot is published before the clipboard write
    // finishes (copied=false, error=''); that also catches message #2
    // arriving while message #1 is still on screen.
    const freshMessage = phase === ReceivePhases.MESSAGE && !state.copied && state.error === '';
    const newPrompt = phase === ReceivePhases.PROMPTING && this.lastReceivePhase !== phase;
    if (freshMessage || newPrompt) {
      this.tabsController.changeIndex(RECEIVE_TAB_INDEX);
    }
    this.lastReceivePhase = phase;
  }

  onPortPublished(): void {
    if (this.portDraft === '' && this.serverPort > 0) {
      this.portDraft = `${this.serverPort}`;
    }
  }

  onAliasPublished(): void {
    if (this.aliasDraft === '' && this.storedAlias !== '') {
      this.aliasDraft = this.storedAlias;
      this.loadSettingDrafts();
    }
  }

  private loadSettingDrafts(): void {
    try {
      const settings = AppContext.getSettings();
      this.pinDraft = settings.pin;
      if (this.portDraft === '') {
        this.portDraft = `${settings.port}`;
      }
    } catch (e) {
      // settings not loaded yet; onAliasPublished retries
    }
  }

  build() {
    Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
      TabContent() {
        this.nearbyTab()
      }
      .tabBar($r('app.string.tab_nearby'))

      TabContent() {
        this.sendTab()
      }
      .tabBar($r('app.string.tab_send'))

      TabContent() {
        this.receiveTab()
      }
      .tabBar($r('app.string.tab_receive'))

      TabContent() {
        this.settingsTab()
      }
      .tabBar($r('app.string.tab_settings'))
    }
    .backgroundColor($r('app.color.app_bg'))
    .barWidth('100%')
  }

  // ----- Nearby -----

  @Builder
  nearbyTab() {
    Column() {
      Row() {
        Text($r('app.string.nearby_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Button($r('app.string.refresh'))
          .fontSize(14)
          .backgroundColor($r('app.color.app_primary'))
          .onClick(() => {
            this.refreshDevices();
          })
      }
      .width('100%')
      .padding(16)

      if (this.devices.length === 0) {
        Column() {
          Text($r('app.string.nearby_empty'))
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .padding(24)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.devices, (device: Device) => {
            ListItem() {
              Row() {
                Column() {
                  Text(device.alias)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                  Text(`${device.deviceModel} · ${device.ip}:${device.port}`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Button($r('app.string.send_to_this_device'))
                  .fontSize(14)
                  .backgroundColor($r('app.color.app_primary'))
                  .enabled(!this.sending)
                  .onClick(() => {
                    this.sendToDevice(device);
                  })
              }
              .width('100%')
              .padding(14)
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(12)
            }
          }, (device: Device) => device.fingerprint)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  private async refreshDevices(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    try {
      await LanShareApp.getInstance().refresh();
    } finally {
      this.refreshing = false;
    }
  }

  // ----- Send -----

  @Builder
  sendTab() {
    Column() {
      Text($r('app.string.send_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding(16)

      Row({ space: 8 }) {
        Button($r('app.string.pick_files'))
          .fontSize(14)
          .backgroundColor($r('app.color.app_primary'))
          .layoutWeight(1)
          .onClick(() => {
            this.pickDocuments();
          })
        Button($r('app.string.pick_photos'))
          .fontSize(14)
          .backgroundColor($r('app.color.app_primary'))
          .layoutWeight(1)
          .onClick(() => {
            this.pickPhotos();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Row({ space: 8 }) {
        Column() {
          // Security component: tapping it grants one-shot clipboard read
          // access, so no READ_PASTEBOARD permission is needed.
          PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE,
            buttonType: ButtonType.Capsule })
            .fontSize(14)
            .backgroundColor($r('app.color.app_primary'))
            .width('100%')
            .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.addClipboardText();
              }
            })
        }
        .layoutWeight(1)
        Button($r('app.string.enter_text'))
          .fontSize(14)
          .backgroundColor($r('app.color.app_primary'))
          .layoutWeight(1)
          .onClick(() => {
            this.showTextEditor = !this.showTextEditor;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 })

      if (this.showTextEditor) {
        Column({ space: 8 }) {
          TextArea({ placeholder: $r('app.string.text_placeholder'), text: this.textDraft })
            .fontSize(14)
            .height(120)
            .onChange((value: string) => {
              this.textDraft = value;
            })
          Row({ space: 8 }) {
            Button($r('app.string.cancel'))
              .fontSize(14)
              .backgroundColor($r('app.color.text_secondary'))
              .layoutWeight(1)
              .onClick(() => {
                this.showTextEditor = false;
              })
            Button($r('app.string.add_text'))
              .fontSize(14)
              .backgroundColor($r('app.color.success'))
              .layoutWeight(1)
              .enabled(this.textDraft.length > 0)
              .onClick(() => {
                this.sendController.addText(this.textDraft);
                this.textDraft = '';
                this.showTextEditor = false;
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8 })
      }

      if (this.sendFiles.length === 0) {
        Column() {
          Text($r('app.string.send_files_empty'))
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .padding(24)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.sendFiles, (file: OutgoingFile) => {
            ListItem() {
              Row() {
                Column() {
                  Text(file.text !== null ? file.text : file.fileName)
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(file.text !== null ? 2 : 1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Row({ space: 6 }) {
                    if (file.text !== null) {
                      Text($r('app.string.text_item'))
                        .fontSize(11)
                        .fontColor($r('app.color.app_primary'))
                        .border({ width: 1, color: $r('app.color.app_primary'), radius: 4 })
                        .padding({ left: 4, right: 4 })
                    }
                    Text(`${this.formatSize(file.size)} · ${this.fileStateLabel(file.state)}`)
                      .fontSize(12)
                      .fontColor(file.state === OutgoingFileStates.FAILED
                        || file.state === OutgoingFileStates.TOO_LARGE
                        ? $r('app.color.danger') : $r('app.color.text_secondary'))
                  }
                  .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding(12)
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(12)
            }
          }, (file: OutgoingFile) => file.id)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12, top: 8 })

        Row({ space: 8 }) {
          TextInput({ placeholder: $r('app.string.pin_label'), text: this.targetPin })
            .type(InputType.Number)
            .fontSize(14)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.targetPin = value;
            })
          Button($r('app.string.clear'))
            .fontSize(14)
            .backgroundColor($r('app.color.text_secondary'))
            .onClick(() => {
              this.sendController.clear();
              this.targetPin = '';
            })
        }
        .width('100%')
        .padding(16)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  private async pickDocuments(): Promise<void> {
    try {
      const docPicker = new picker.DocumentViewPicker(getContext(this));
      const uris = await docPicker.select();
      if (uris !== undefined && uris !== null) {
        this.sendController.addUris(uris);
      }
    } catch (e) {
      this.toast('pick failed');
    }
  }

  /** Called after the PasteButton granted clipboard access. */
  private async addClipboardText(): Promise<void> {
    let text = '';
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      text = data.getPrimaryText() ?? '';
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[LanShare][UI] clipboard read failed: ${err.message ?? 'unknown'}`);
    }
    if (text.length === 0) {
      promptAction.showToast({ message: $r('app.string.clipboard_empty'), duration: 2500 });
      return;
    }
    this.sendController.addText(text);
    promptAction.showToast({ message: $r('app.string.clipboard_added'), duration: 2000 });
  }

  private async pickPhotos(): Promise<void> {
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO;
      options.maxSelectNumber = 20;
      const result = await photoPicker.select(options);
      if (result.photoUris !== undefined && result.photoUris !== null) {
        this.sendController.addUris(result.photoUris);
      }
    } catch (e) {
      this.toast('pick failed');
    }
  }

  private async sendToDevice(device: Device): Promise<void> {
    if (this.sending) {
      return;
    }
    if (!this.sendController.hasReadyFiles()) {
      promptAction.showToast({ message: $r('app.string.send_files_empty'), duration: 2500 });
      return;
    }
    this.sending = true;
    promptAction.showToast({ message: $r('app.string.sending'), duration: 1000 });
    const result = await this.sendController.sendTo(device, this.targetPin);
    this.sending = false;
    let message: Resource = $r('app.string.send_done');
    if (result.outcome === SendResult.OK) {
      message = $r('app.string.send_done');
      this.sendController.clear();
    } else if (result.outcome === SendResult.PIN_REQUIRED) {
      message = $r('app.string.pin_required');
    } else if (result.outcome === SendResult.PIN_LOCKED) {
      message = $r('app.string.pin_locked');
    } else if (result.outcome === SendResult.DECLINED) {
      message = $r('app.string.send_declined');
    } else if (result.outcome === SendResult.BUSY) {
      message = $r('app.string.send_busy');
    } else if (result.outcome === SendResult.EMPTY) {
      message = $r('app.string.send_files_empty');
    } else {
      message = $r('app.string.send_failed');
    }
    promptAction.showToast({ message: message, duration: 3000 });
  }

  private fileStateLabel(state: string): string {
    if (state === OutgoingFileStates.READY) {
      return '·';
    }
    if (state === OutgoingFileStates.UPLOADING) {
      return '↑';
    }
    if (state === OutgoingFileStates.DONE) {
      return '✓';
    }
    if (state === OutgoingFileStates.TOO_LARGE) {
      return '64MB+';
    }
    return '✗';
  }

  // ----- Receive -----

  @Builder
  receiveTab() {
    Column() {
      Text($r('app.string.receive_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding(16)

      Row() {
        Text(this.serverPort > 0
          ? $r('app.string.server_running', this.serverPort)
          : $r('app.string.server_not_running'))
          .fontSize(13)
          .fontColor(this.serverPort > 0 ? $r('app.color.success') : $r('app.color.danger'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      Column() {
        if (this.receiveState.phase === ReceivePhases.PROMPTING) {
          this.promptCard()
        } else if (this.receiveState.phase === ReceivePhases.MESSAGE) {
          this.messageCard()
        } else if (this.receiveState.phase === ReceivePhases.WAITING
          || this.receiveState.phase === ReceivePhases.RECEIVING
          || this.receiveState.phase === ReceivePhases.SAVING
          || this.receiveState.phase === ReceivePhases.READY_TO_SAVE
          || this.receiveState.phase === ReceivePhases.SAVED
          || this.receiveState.phase === ReceivePhases.FAILED) {
          this.progressCard()
        } else {
          Text($r('app.string.server_running', this.serverPort > 0 ? this.serverPort : 53317))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .padding(24)
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  promptCard() {
    Column() {
      Text($r('app.string.incoming_request'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text($r('app.string.incoming_from',
        this.receiveState.senderAlias === '' ? this.receiveState.senderIp : this.receiveState.senderAlias))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 4 })
        .width('100%')

      List() {
        ForEach(this.receiveState.files, (file: IncomingFile) => {
          ListItem() {
            Row() {
              Text(file.fileName)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(file.skipped ? $r('app.string.file_skipped') : this.formatSize(file.size))
                .fontSize(12)
                .fontColor(file.skipped ? $r('app.color.danger') : $r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
          }
        }, (file: IncomingFile) => file.id)
      }
      .width('100%')
      .margin({ top: 8 })

      Row({ space: 12 }) {
        Button($r('app.string.decline'))
          .fontSize(14)
          .backgroundColor($r('app.color.danger'))
          .layoutWeight(1)
          .onClick(() => {
            ReceiveController.getInstance().declineFromUi();
          })
        Button($r('app.string.accept_all'))
          .fontSize(14)
          .backgroundColor($r('app.color.success'))
          .layoutWeight(1)
          .onClick(() => {
            ReceiveController.getInstance().acceptFromUi();
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)
    .margin(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  messageCard() {
    Column() {
      Text($r('app.string.message_received'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text($r('app.string.incoming_from',
        this.receiveState.senderAlias === '' ? this.receiveState.senderIp : this.receiveState.senderAlias))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 4 })
        .width('100%')

      Scroll() {
        Text(this.receiveState.message)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 360 })
      .align(Alignment.TopStart)
      .margin({ top: 12 })

      if (this.receiveState.copied) {
        Text($r('app.string.message_copied'))
          .fontSize(12)
          .fontColor($r('app.color.success'))
          .margin({ top: 8 })
          .width('100%')
      } else if (this.receiveState.error !== '') {
        Text($r('app.string.message_copy_failed'))
          .fontSize(12)
          .fontColor($r('app.color.danger'))
          .margin({ top: 8 })
          .width('100%')
      }

      Row({ space: 12 }) {
        Button($r('app.string.close'))
          .fontSize(14)
          .backgroundColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .onClick(() => {
            ReceiveController.getInstance().dismissMessage();
          })
        Button($r('app.string.copy'))
          .fontSize(14)
          .backgroundColor($r('app.color.app_primary'))
          .layoutWeight(1)
          .onClick(() => {
            ReceiveController.getInstance().copyMessage();
          })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)
    .margin(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  progressCard() {
    Column() {
      if (this.receiveState.phase === ReceivePhases.WAITING) {
        Text($r('app.string.waiting_sender'))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      } else if (this.receiveState.phase === ReceivePhases.RECEIVING
        || this.receiveState.phase === ReceivePhases.SAVING) {
        Text(this.receiveState.phase === ReceivePhases.SAVING
          ? $r('app.string.saving_files') : $r('app.string.receiving_files'))
          .fontSize(14)
          .fontColor($r('app.color.app_primary'))
          .width('100%')
      } else if (this.receiveState.phase === ReceivePhases.SAVED) {
        Text($r('app.string.receive_saved'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.success'))
          .width('100%')
      } else if (this.receiveState.phase === ReceivePhases.FAILED) {
        Text($r('app.string.receive_failed'))
          .fontSize(14)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }

      Text($r('app.string.incoming_from',
        this.receiveState.senderAlias === '' ? this.receiveState.senderIp : this.receiveState.senderAlias))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 4 })
        .width('100%')

      List() {
        ForEach(this.receiveState.files, (file: IncomingFile) => {
          ListItem() {
            Row() {
              Text(file.fileName)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(file.skipped ? '✗' : (file.done ? '✓' : '…'))
                .fontSize(14)
                .fontColor(file.done ? $r('app.color.success')
                  : (file.skipped ? $r('app.color.danger') : $r('app.color.text_secondary')))
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
          }
        }, (file: IncomingFile) => file.id)
      }
      .width('100%')
      .margin({ top: 8 })

      if (this.receiveState.phase === ReceivePhases.READY_TO_SAVE) {
        Button($r('app.string.save_files'))
          .fontSize(14)
          .backgroundColor($r('app.color.app_primary'))
          .width('100%')
          .margin({ top: 12 })
          .onClick(() => {
            ReceiveController.getInstance().saveToUser();
          })
      }
    }
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)
    .margin(12)
    .alignItems(HorizontalAlign.Start)
  }

  // ----- Settings -----

  @Builder
  settingsTab() {
    Column() {
      Text($r('app.string.settings_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding(16)

      Column() {
        Text($r('app.string.settings_alias'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextInput({ text: this.aliasDraft })
          .fontSize(14)
          .width('100%')
          .margin({ top: 4 })
          .onChange((value: string) => {
            this.aliasDraft = value;
          })

        Text($r('app.string.settings_port'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 16 })
        TextInput({ text: this.portDraft })
          .type(InputType.Number)
          .fontSize(14)
          .width('100%')
          .margin({ top: 4 })
          .onChange((value: string) => {
            this.portDraft = value;
          })

        Text($r('app.string.settings_pin'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 16 })
        TextInput({ text: this.pinDraft })
          .type(InputType.Number)
          .fontSize(14)
          .width('100%')
          .margin({ top: 4 })
          .onChange((value: string) => {
            this.pinDraft = value;
          })

        Text($r('app.string.settings_security_note'))
          .fontSize(12)
          .fontColor($r('app.color.warning'))
          .width('100%')
          .margin({ top: 16 })

        Row() {
          Text($r('app.string.protocol_value', this.protocol))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 8 })
        Text($r('app.string.fingerprint_value', this.fingerprint))
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })

        Button($r('app.string.save'))
          .fontSize(14)
          .backgroundColor($r('app.color.app_primary'))
          .width('100%')
          .margin({ top: 20 })
          .onClick(() => {
            this.saveSettings();
          })
      }
      .padding(16)
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius(12)
      .margin(12)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  private async saveSettings(): Promise<void> {
    try {
      const settings = AppContext.getSettings();
      settings.alias = this.aliasDraft.trim().length > 0 ? this.aliasDraft.trim() : settings.alias;
      const previousPort = settings.port;
      const port = parseInt(this.portDraft, 10);
      if (!isNaN(port) && port > 0 && port < 65536) {
        settings.port = port;
      }
      settings.pin = this.pinDraft.trim();
      await settings.save();
      AppContext.refreshIdentity();
      AppStorage.setOrCreate('lanshare_alias', settings.alias);
      promptAction.showToast({
        message: settings.port !== previousPort ? $r('app.string.port_restart_hint') : $r('app.string.saved'),
        duration: 2500
      });
    } catch (e) {
      this.toast('not ready yet');
    }
  }

  // ----- helpers -----

  private formatSize(size: number): string {
    if (size < 1024) {
      return `${size} B`;
    }
    if (size < 1024 * 1024) {
      return `${(size / 1024).toFixed(1)} KB`;
    }
    return `${(size / 1024 / 1024).toFixed(1)} MB`;
  }

  private toast(message: string): void {
    promptAction.showToast({ message: message, duration: 2000 });
  }
}
